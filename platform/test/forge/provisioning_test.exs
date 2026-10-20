defmodule Forge.ProvisioningTest do
  @moduledoc """
  Worker templates, provider credentials, and who may point whose money at which project.

  `docs/design/provisioning.md`. The assertions that matter here are the two guards — a
  template belongs to the user who made it, and only that user may assign it, and only to a
  project they are in — and the two rules that keep a template a *recipe*: its values are
  copied at creation, and editing it afterwards changes nothing that exists.
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.Provisioning
  alias Forge.Provisioning.{Credential, Template, Vault}

  setup do
    Forge.Provider.Fake.watch()
    %{user: user_fixture()}
  end

  describe "the vault" do
    test "a secret comes back exactly as it went in" do
      secret = %{"token" => "hcloud-abc", "extra" => "second field"}

      sealed = Vault.seal(secret)
      refute sealed =~ "hcloud-abc"
      assert Vault.open(sealed) == {:ok, secret}
    end

    # Authenticated encryption, so a ciphertext somebody has edited is refused rather than
    # decrypted into something else. Also the rotated-key case, which is the one an operator
    # will actually hit.
    test "anything that is not exactly what was sealed is refused" do
      sealed = Vault.seal(%{"token" => "t"})

      assert Vault.open(nil) == :error
      assert Vault.open("") == :error
      assert Vault.open("XCP.not-really") == :error
      assert Vault.open(sealed <> "x") == :error
    end
  end

  describe "provider credentials" do
    test "the secret is stored sealed and read back whole", %{user: user} do
      assert {:ok, credential} =
               Provisioning.create_credential(user, %{
                 name: "hetzner",
                 provider: "fake",
                 secret: %{"token" => "abc"}
               })

      refute credential.secret =~ "abc"
      assert Credential.secret(credential) == {:ok, %{"token" => "abc"}}
    end

    # A credential naming a provider this node cannot speak to can never be used, and the error
    # belongs where the name was typed rather than at the first create that asks for it.
    test "a provider this node does not know is refused", %{user: user} do
      assert {:error, changeset} =
               Provisioning.create_credential(user, %{
                 name: "x",
                 provider: "nowhere",
                 secret: %{"token" => "abc"}
               })

      assert %{provider: ["is not a provider this node knows"]} = errors_on(changeset)
    end

    # **A provider that takes no credential cannot have one.** Without this the failure is
    # `secret is required` against a form with no fields in it, which reads as a broken form
    # rather than as a category that does not exist — which is how it was found.
    test "a provider that needs no credential is refused one", %{user: user} do
      assert {:error, changeset} =
               Provisioning.create_credential(user, %{
                 name: "pointless",
                 provider: "local",
                 secret: %{"token" => "abc"}
               })

      assert %{provider: ["needs no credential"]} = errors_on(changeset)
    end

    test "a secret with nothing in it is not a secret", %{user: user} do
      for secret <- [%{}, %{"token" => ""}, %{"token" => nil}, nil] do
        assert {:error, changeset} =
                 Provisioning.create_credential(user, %{
                   name: "x-#{System.unique_integer([:positive])}",
                   provider: "fake",
                   secret: secret
                 })

        assert Map.has_key?(errors_on(changeset), :secret), "#{inspect(secret)} should be refused"
      end
    end

    # The scoping rule, and the one worth a mutation: an id is not a capability.
    test "one user never reaches another's", %{user: user} do
      other = user_fixture()

      {:ok, theirs} =
        Provisioning.create_credential(other, %{
          name: "theirs",
          provider: "fake",
          secret: %{"token" => "t"}
        })

      assert Provisioning.credential(user, theirs.id) == nil
      assert Provisioning.credentials(user) == []
      assert Provisioning.delete_credential(user, theirs.id) == {:error, :not_found}
    end
  end

  describe "templates" do
    test "a template records what a machine made from it will be", %{user: user} do
      assert {:ok, template} = create_template(user, %{memory: 8_000, cores: 4, image: "snap-1"})

      # Its owner too: a machine made from a template is the template owner's
      # (`identity.md` § Workers). And the image, so that a machine refused at its join teaches
      # the template about the snapshot it was made from and not about whatever the template
      # names by then (`provisioning.md` § A snapshot that speaks the wrong protocol).
      assert Template.worker_attrs(template) == %{
               provider: "fake",
               template_id: template.id,
               user_id: user.id,
               provider_credential_id: nil,
               memory_budget: 8_000,
               cores: 4,
               accepts: nil,
               image: "snap-1"
             }
    end

    # A template naming one provider and holding another's credential would make a machine in
    # the wrong account, or fail at the API with a message about a token rather than the row.
    test "a credential for another provider is refused", %{user: user} do
      {:ok, credential} =
        Provisioning.create_credential(user, %{
          name: "another account",
          provider: "hetzner",
          secret: %{"token" => "t"}
        })

      assert {:error, changeset} =
               create_template(user, %{provider: "fake", provider_credential_id: credential.id})

      assert %{provider_credential_id: ["is for hetzner, not fake"]} = errors_on(changeset)
    end

    # The hole this closes: the form only *offers* the caller's own credentials, and the changeset
    # checked the provider and nothing else, so an id off the wire made a template that created
    # machines in somebody else's account. Editing is the same changeset and the same hole.
    test "a template cannot name somebody else's credential, made or edited", %{user: user} do
      {:ok, theirs} =
        Provisioning.create_credential(user_fixture(), %{
          name: "their account",
          provider: "fake",
          secret: %{"token" => "t"}
        })

      assert {:error, changeset} =
               create_template(user, %{provider: "fake", provider_credential_id: theirs.id})

      assert %{provider_credential_id: ["is not one of your credentials"]} = errors_on(changeset)

      {:ok, mine} = create_template(user, %{provider: "fake"})

      assert {:error, changeset} =
               Provisioning.update_template(user, mine.id, %{
                 provider_credential_id: theirs.id
               })

      assert %{provider_credential_id: ["is not one of your credentials"]} = errors_on(changeset)
    end

    # An id naming nothing is answered by the same guard, in the same words, rather than left to
    # the foreign key: from the outside it is indistinguishable from somebody else's.
    test "a credential id naming nothing is not one of yours", %{user: user} do
      assert {:error, changeset} =
               create_template(user, %{
                 provider: "fake",
                 provider_credential_id: Ecto.UUID.generate()
               })

      assert %{provider_credential_id: ["is not one of your credentials"]} = errors_on(changeset)
    end

    # The credential is checked as the template now stands, not only when its id changes: a
    # provider edited under a credential it already holds is the same mismatch as a new one.
    test "changing the provider re-checks the credential already held", %{user: user} do
      {:ok, mine} =
        Provisioning.create_credential(user, %{
          name: "mine-#{System.unique_integer([:positive])}",
          provider: "fake",
          secret: %{"token" => "t"}
        })

      {:ok, template} = create_template(user, %{provider_credential_id: mine.id})

      assert {:error, changeset} =
               Provisioning.update_template(user, template.id, %{provider: "local"})

      assert %{provider_credential_id: ["is for fake, not local"]} = errors_on(changeset)
    end

    # The other side of the guard: refusing every credential would pass the test above.
    test "the owner's own credential is taken", %{user: user} do
      {:ok, mine} =
        Provisioning.create_credential(user, %{
          name: "mine",
          provider: "fake",
          secret: %{"token" => "t"}
        })

      assert {:ok, template} = create_template(user, %{provider_credential_id: mine.id})
      assert template.provider_credential_id == mine.id
    end

    # A local template is the case that has no credential at all, and it must stay creatable:
    # the local driver reaches its machines without an account.
    test "a template for a provider that needs no credential is fine without one", %{user: user} do
      assert {:ok, template} = create_template(user, %{provider: "local"})
      assert template.provider_credential_id == nil
      # Nor a size or an image: the local driver reads neither from a template.
      assert template.size == nil
      assert template.image == nil
    end

    # `Forge.Provider.Hetzner` refuses a create with no image or no server type, and there is no
    # node-wide image for it to fall back to, so a template naming neither could only ever fail.
    # It is refused where it is typed, by the driver's own declaration.
    test "a provider that cannot make a machine without an image or a size requires both",
         %{user: user} do
      assert {:error, changeset} = create_template(user, %{provider: "hetzner"})
      assert %{image: ["can't be blank"], size: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} = create_template(user, %{provider: "hetzner", size: "cpx32"})
      assert errors_on(changeset) == %{image: ["can't be blank"]}

      assert {:error, changeset} = create_template(user, %{provider: "hetzner", image: "42"})
      assert errors_on(changeset) == %{size: ["can't be blank"]}

      assert {:ok, template} =
               create_template(user, %{provider: "hetzner", size: "cpx32", image: "42"})

      assert template.image == "42"
    end

    # Asked of the template as it stands, not only of what an edit changed: a Hetzner row saved
    # before the rule — forced in here, since the changeset no longer lets one be made — cannot
    # be renamed without being given the image it lacks.
    test "an edit is held to it too, so a row from before the rule has to be given an image",
         %{user: user} do
      {:ok, template} = create_template(user, %{provider: "hetzner", size: "cpx32", image: "42"})

      {1, _} =
        Repo.update_all(from(t in Template, where: t.id == ^template.id), set: [image: nil])

      assert {:error, changeset} =
               Provisioning.update_template(user, template.id, %{name: "renamed"})

      assert errors_on(changeset) == %{image: ["can't be blank"]}

      assert {:ok, _} =
               Provisioning.update_template(user, template.id, %{name: "renamed", image: "43"})
    end

    test "zero machines is a template turned off, not an unlimited one", %{user: user} do
      assert {:ok, template} = create_template(user, %{max_workers: 0})
      assert template.max_workers == 0

      assert {:error, changeset} = create_template(user, %{max_workers: -1})
      assert Map.has_key?(errors_on(changeset), :max_workers)
    end

    test "one user never reaches another's", %{user: user} do
      other = user_fixture()
      {:ok, theirs} = create_template(other, %{})

      assert Provisioning.template(user, theirs.id) == nil
      assert Provisioning.templates(user) == []
      assert Provisioning.delete_template(user, theirs.id) == {:error, :not_found}
    end

    # **The edit is guarded here, not on the page.** It used to take the row and no actor, and
    # the templates page reading the row scoped to the caller was the only thing deciding whose
    # it was (`docs/design/identity.md` § Where the guard lives). The id is the client's.
    test "an edit reaches only the caller's own template", %{user: user} do
      {:ok, theirs} = create_template(user_fixture(), %{name: "theirs"})

      for id <- [theirs.id, Ecto.UUID.generate(), "not-a-uuid", nil] do
        assert Provisioning.update_template(user, id, %{name: "stolen"}) == {:error, :not_found}
      end

      assert Repo.get!(Template, theirs.id).name == "theirs"
    end

    # And the owner is the context's to set, as it is on create: an edit carrying a `user_id`
    # would otherwise hand the template — and every machine it bills — to another account.
    test "an edit cannot hand a template to somebody else", %{user: user} do
      other = user_fixture()
      {:ok, mine} = create_template(user, %{name: "mine"})

      assert {:ok, saved} =
               Provisioning.update_template(user, mine.id, %{
                 "name" => "renamed",
                 "user_id" => other.id
               })

      assert saved.name == "renamed"
      assert Repo.get!(Template, mine.id).user_id == user.id
    end
  end

  # What the chosen snapshot carries, read from the listing on save or learnt from a machine
  # refused at join (`docs/design/provisioning.md` § A snapshot that speaks the wrong protocol).
  describe "what a template knows about its image" do
    test "the labels are kept as they were given", %{user: user} do
      {:ok, template} =
        create_template(user, %{image: "snap-1", image_build: "8rh57whmgk6m", image_protocol: 1})

      assert {template.image_build, template.image_protocol} == {"8rh57whmgk6m", 1}
    end

    # **A rename must not forget a learnt protocol**, or it earns a snapshot known to be refused
    # one more machine: the listing says nothing about an unlabelled snapshot, and saving reads
    # the listing.
    test "a save with no label for the same image keeps what is known", %{user: user} do
      {:ok, template} = create_template(user, %{image: "snap-1"})
      :ok = Provisioning.learn_protocol(template.id, "snap-1", 7, "8rh57whmgk6m")

      {:ok, saved} =
        Provisioning.update_template(user, template.id, %{
          name: "renamed",
          image: "snap-1",
          image_build: nil,
          image_protocol: nil
        })

      assert {saved.image_protocol, saved.image_build} == {7, "8rh57whmgk6m"}
    end

    test "a label that is there replaces what is known", %{user: user} do
      {:ok, template} = create_template(user, %{image: "snap-1"})
      :ok = Provisioning.learn_protocol(template.id, "snap-1", 7)

      {:ok, saved} =
        Provisioning.update_template(user, template.id, %{image: "snap-1", image_protocol: 1})

      assert saved.image_protocol == 1
    end

    # Another snapshot is another question, and what was learnt about the last one is no answer.
    test "another image takes its own labels, nothing included", %{user: user} do
      {:ok, template} =
        create_template(user, %{image: "snap-1", image_build: "aaaaaaaaaaaa", image_protocol: 7})

      {:ok, saved} =
        Provisioning.update_template(user, template.id, %{
          image: "snap-2",
          image_build: nil,
          image_protocol: nil
        })

      assert {saved.image_build, saved.image_protocol} == {nil, nil}
    end

    test "is learnt only while the template names the image that was refused", %{user: user} do
      {:ok, template} = create_template(user, %{image: "snap-2"})

      :ok = Provisioning.learn_protocol(template.id, "snap-1", 7)
      assert Repo.get!(Template, template.id).image_protocol == nil

      :ok = Provisioning.learn_protocol(template.id, nil, 7)
      assert Repo.get!(Template, template.id).image_protocol == nil

      :ok = Provisioning.learn_protocol(template.id, "snap-2", 7)
      assert Repo.get!(Template, template.id).image_protocol == 7
    end

    # What one template learns is its own. Another naming the same snapshot id — another
    # person's, or another provider's, where the id means something else — learns nothing from a
    # machine it did not make.
    test "is learnt by the one template, not every template naming the image", %{user: user} do
      {:ok, mine} = create_template(user, %{image: "snap-1"})
      {:ok, theirs} = create_template(user_fixture(), %{image: "snap-1"})

      :ok = Provisioning.learn_protocol(mine.id, "snap-1", 7)

      assert Repo.get!(Template, mine.id).image_protocol == 7
      assert Repo.get!(Template, theirs.id).image_protocol == nil
    end
  end

  # A template may name the mark instead of a snapshot, and then what it is made from is whichever
  # snapshot carries the mark at the moment of creation (`docs/design/provisioning.md` § Where a
  # machine comes from).
  describe "a template that follows the latest mark" do
    test "a snapshot id resolves to itself", %{user: user} do
      {:ok, template} = create_template(user, %{image: "snap-1"})
      assert template.resolved_image == "snap-1"

      {:ok, saved} = Provisioning.update_template(user, template.id, %{image: "snap-2"})
      assert saved.resolved_image == "snap-2"
    end

    # The id a form sends cannot talk the template onto another snapshot than the one it names:
    # `image` is what decides, every time it changes.
    test "a resolved image from the form is overruled by the image itself", %{user: user} do
      {:ok, template} =
        create_template(user, %{image: "snap-1", resolved_image: "somebody-elses-snapshot"})

      assert template.resolved_image == "snap-1"
    end

    # The word is not a snapshot, so what it resolves to is the caller's: the catalogue's marked
    # entry at save time, and a fresh resolution at every create.
    test "the mark resolves to what the caller found, not to itself", %{user: user} do
      {:ok, template} =
        create_template(user, %{image: "latest", resolved_image: "snap-7"})

      assert {template.image, template.resolved_image} == {"latest", "snap-7"}
      assert Template.latest?(template)
    end

    # The rule `keep_what_was_learnt/1` already kept for the labels: a rename carries no answer
    # about what the mark points at, and reading its own column as that answer would unresolve it.
    test "a save that says nothing new keeps what it resolved to", %{user: user} do
      {:ok, template} = create_template(user, %{image: "latest", resolved_image: "snap-7"})

      {:ok, saved} =
        Provisioning.update_template(user, template.id, %{
          name: "renamed",
          resolved_image: nil,
          image_build: nil,
          image_protocol: nil
        })

      assert saved.resolved_image == "snap-7"
    end

    test "the newest of the snapshots marked is the one the mark means" do
      images = [
        %{id: "old", name: "old", created: "2026-10-01T00:00:00+00:00", current: true},
        %{id: "new", name: "new", created: "2026-10-20T00:00:00+00:00", current: true},
        %{id: "newest-unmarked", name: "u", created: "2026-10-21T00:00:00+00:00"}
      ]

      assert %{id: "new"} = Provisioning.current_image(images)
    end

    test "an account with nothing marked carries no mark" do
      assert Provisioning.current_image([]) == nil
      assert Provisioning.current_image([%{id: "a", name: "a", current: false}]) == nil
      assert Provisioning.current_image([%{id: "a", name: "a"}]) == nil
    end

    test "resolving takes the snapshot's own labels", %{user: user} do
      {:ok, template} = create_template(user, %{image: "latest"})

      resolved =
        Provisioning.resolve_latest(template, %{
          id: "snap-9",
          name: "nine",
          build: "aaaaaaaaaaaa",
          protocol: 4
        })

      assert {resolved.resolved_image, resolved.image_build, resolved.image_protocol} ==
               {"snap-9", "aaaaaaaaaaaa", 4}

      stored = Repo.get!(Template, template.id)

      assert {stored.resolved_image, stored.image_build, stored.image_protocol} ==
               {"snap-9", "aaaaaaaaaaaa", 4}
    end

    # Another snapshot is another question, and what was learnt about the last one is no answer —
    # the same rule a save keeps when the image changes.
    test "resolving onto another snapshot forgets the last one's labels", %{user: user} do
      {:ok, template} =
        create_template(user, %{
          image: "latest",
          resolved_image: "snap-8",
          image_build: "bbbbbbbbbbbb",
          image_protocol: 4
        })

      resolved = Provisioning.resolve_latest(template, %{id: "snap-9", name: "nine"})

      assert {resolved.resolved_image, resolved.image_build, resolved.image_protocol} ==
               {"snap-9", nil, nil}
    end

    # **The loop this rule exists to stop.** An unlabelled snapshot's protocol is learnt from the
    # machine that was refused for it; a resolution that read the listing's silence as *unknown*
    # would forget it and earn that snapshot another machine on every pass.
    test "resolving onto the same snapshot keeps what a refused machine taught", %{user: user} do
      {:ok, template} = create_template(user, %{image: "latest", resolved_image: "snap-9"})
      :ok = Provisioning.learn_protocol(template.id, "snap-9", 7, "cccccccccccc")
      template = Repo.get!(Template, template.id)

      resolved = Provisioning.resolve_latest(template, %{id: "snap-9", name: "nine"})

      assert {resolved.image_build, resolved.image_protocol} == {"cccccccccccc", 7}
    end

    test "a label that is there still replaces what was learnt", %{user: user} do
      {:ok, template} = create_template(user, %{image: "latest", resolved_image: "snap-9"})
      :ok = Provisioning.learn_protocol(template.id, "snap-9", 7, "cccccccccccc")
      template = Repo.get!(Template, template.id)

      resolved =
        Provisioning.resolve_latest(template, %{
          id: "snap-9",
          name: "n",
          build: "dddddddddddd",
          protocol: 2
        })

      assert {resolved.image_build, resolved.image_protocol} == {"dddddddddddd", 2}
    end

    # Nothing is written when the three fields already say this, which is the common case: the
    # mark moves when an image is built, not between two scheduling passes.
    test "resolving onto what it already resolved writes nothing", %{user: user} do
      {:ok, template} =
        create_template(user, %{
          image: "latest",
          resolved_image: "snap-9",
          image_build: "aaaaaaaaaaaa",
          image_protocol: 4
        })

      was = Repo.get!(Template, template.id).updated_at

      {1, _} =
        Repo.update_all(from(t in Template, where: t.id == ^template.id),
          set: [updated_at: DateTime.add(was, -3600, :second)]
        )

      moved_back = Repo.get!(Template, template.id).updated_at

      _same =
        Provisioning.resolve_latest(Repo.get!(Template, template.id), %{
          id: "snap-9",
          name: "nine",
          build: "aaaaaaaaaaaa",
          protocol: 4
        })

      assert Repo.get!(Template, template.id).updated_at == moved_back
    end

    # **A save must not carry one snapshot's labels onto another.** `image` is the word for a
    # template on the mark and never changes, so deciding by it meant a rename after the mark had
    # moved wrote the old snapshot's build and protocol onto the new one — a machine made from an
    # unprobed snapshot on a protocol nobody had verified.
    test "a save onto a newly marked snapshot takes its labels, nothing included", %{user: user} do
      {:ok, template} =
        create_template(user, %{
          image: "latest",
          resolved_image: "snap-x",
          image_build: "aaaaaaaaaaaa",
          image_protocol: 6
        })

      # What the page sends for a rename once the mark has moved to an unlabelled snapshot.
      {:ok, saved} =
        Provisioning.update_template(user, template.id, %{
          name: "renamed",
          image: "latest",
          resolved_image: "snap-y",
          image_build: nil,
          image_protocol: nil
        })

      assert {saved.resolved_image, saved.image_build, saved.image_protocol} ==
               {"snap-y", nil, nil}
    end

    # The other half of the same rule, and the one that was already right: staying on the snapshot
    # it is on keeps what a refused machine taught about it.
    test "a save that stays on the same snapshot keeps what was learnt", %{user: user} do
      {:ok, template} = create_template(user, %{image: "latest", resolved_image: "snap-x"})
      :ok = Provisioning.learn_protocol(template.id, "snap-x", 6, "aaaaaaaaaaaa")

      {:ok, saved} =
        Provisioning.update_template(user, template.id, %{
          name: "renamed",
          image: "latest",
          resolved_image: "snap-x",
          image_build: nil,
          image_protocol: nil
        })

      assert {saved.image_build, saved.image_protocol} == {"aaaaaaaaaaaa", 6}
    end

    # **The most ordinary thing an operator does here: point a template at a new snapshot.** Every
    # snapshot built from one release carries the same protocol, so the new one's protocol usually
    # equals the stored one — and `cast/3` registers no change for a value equal to the row, so
    # reading what the listing offered with `get_change/2` read it as *nothing offered* and wiped
    # the protocol. The page then said *unlabelled*, the next create was spent as a probe, and a
    # snapshot the platform would have refused before paying cost a machine instead.
    test "a repoint onto a snapshot of the same protocol keeps the protocol", %{user: user} do
      current = ForgeCore.WorkerProtocol.current()

      {:ok, template} =
        create_template(user, %{
          image: "snap-a",
          image_build: "aaaaaaaaaaaa",
          image_protocol: current
        })

      {:ok, saved} =
        Provisioning.update_template(user, template.id, %{
          image: "snap-b",
          image_build: "bbbbbbbbbbbb",
          image_protocol: current
        })

      assert {saved.resolved_image, saved.image_build, saved.image_protocol} ==
               {"snap-b", "bbbbbbbbbbbb", current}
    end

    # **The dead comparison this column exists to prevent.** `workers.image` is always a concrete
    # snapshot and a template naming the mark never holds one in `image`, so a counter keyed on
    # `image` could never reset for one and a protocol could never be learnt — silently, for ever.
    test "its counter and its protocol are keyed on what it resolved to", %{user: user} do
      {:ok, template} = create_template(user, %{image: "latest", resolved_image: "snap-9"})
      for _ <- 1..Provisioning.failure_limit(), do: Provisioning.failed(template.id, "nope")

      refute Provisioning.succeeded(template.id, "latest")
      assert Provisioning.disabled?(Repo.get!(Template, template.id))

      :ok = Provisioning.learn_protocol(template.id, "latest", 7)
      assert Repo.get!(Template, template.id).image_protocol == nil

      assert Provisioning.succeeded(template.id, "snap-9")
      refute Provisioning.disabled?(Repo.get!(Template, template.id))

      :ok = Provisioning.learn_protocol(template.id, "snap-9", 7)
      assert Repo.get!(Template, template.id).image_protocol == 7
    end
  end

  describe "assigning a template to a project" do
    setup %{user: user} do
      {:ok, project} = Forge.Projects.register(project_attrs(), user)
      {:ok, template} = create_template(user, %{})
      %{project: project, template: template}
    end

    # And both are in the event log: which account a project's machines are billed to is a
    # decision about money, and `decisions.md` has every mutation audited.
    test "the owner may, for a project they are in, and it is recorded", context do
      %{user: user, project: project, template: template} = context

      assert {:ok, _} = Provisioning.assign(user, template.id, project.id)
      assert Enum.map(Provisioning.for_project(project.id), & &1.id) == [template.id]

      assert :ok = Provisioning.unassign(user, template.id, project.id)
      assert Provisioning.for_project(project.id) == []

      types =
        Repo.all(
          from e in Forge.Events.Event,
            where: e.project_id == ^project.id and like(e.type, "template.%"),
            order_by: e.seq,
            select: {e.type, e.actor}
        )

      assert types == [
               {"template.assigned", %{"kind" => "user", "id" => user.id}},
               {"template.unassigned", %{"kind" => "user", "id" => user.id}}
             ]
    end

    # `identity.md` § Workers, with the noun changed: a project admin cannot reach for somebody
    # else's template, because creating from it spends its owner's credential.
    test "somebody else may not, even as an admin of the project", context do
      %{project: project, template: template} = context
      intruder = user_fixture()
      join!(project, intruder, :admin)

      assert Provisioning.assign(intruder, template.id, project.id) == {:error, :not_found}
      assert Provisioning.unassign(intruder, template.id, project.id) == {:error, :not_found}
      assert Provisioning.for_project(project.id) == []
    end

    # The other half: a template's owner may not point their own spending at a project they
    # have nothing to do with.
    test "the owner may not, for a project they are not in", %{user: user, template: template} do
      {:ok, elsewhere} = register_owned!(project_attrs())

      assert Provisioning.assign(user, template.id, elsewhere.id) == {:error, :not_a_member}
      assert Provisioning.for_project(elsewhere.id) == []
    end
  end

  # What a machine made from a template would be billed to, asked again at creation because a
  # changeset guards only the rows written after it (`Forge.Workers` is the caller; its tests
  # force a row onto another user's credential and watch nothing be made).
  describe "the credential a machine would spend" do
    test "the owner's own is spendable, and no credential is nothing to check", %{user: user} do
      {:ok, mine} =
        Provisioning.create_credential(user, %{
          name: "mine",
          provider: "fake",
          secret: %{"token" => "t"}
        })

      {:ok, template} = create_template(user, %{provider_credential_id: mine.id})
      assert {:ok, %Credential{id: id}} = Provisioning.spendable_credential(template)
      assert id == mine.id

      {:ok, bare} = create_template(user, %{})
      assert Provisioning.spendable_credential(bare) == {:ok, nil}
    end

    # Deleting a credential nilifies the column, so a template read before the delete names an
    # id with no row behind it. That is a template with no credential, and the driver says what
    # that means — not a crash in the scheduler.
    test "a credential deleted since the template was read is no credential", %{user: user} do
      {:ok, mine} =
        Provisioning.create_credential(user, %{
          name: "going",
          provider: "fake",
          secret: %{"token" => "t"}
        })

      {:ok, stale} = create_template(user, %{provider_credential_id: mine.id})
      :ok = Provisioning.delete_credential(user, mine.id)

      assert Provisioning.spendable_credential(stale) == {:ok, nil}
    end
  end

  describe "choosing a template for a job" do
    setup %{user: user} do
      {:ok, project} = Forge.Projects.register(project_attrs(), user)
      %{project: project}
    end

    # Smallest that fits, not first assigned: creating a thirty-two core machine for a job that
    # asked for one is how a fleet gets expensive without anybody deciding that it should.
    test "the smallest that fits wins", %{user: user, project: project} do
      small = assigned(user, project, %{name: "small", memory: 2_000, cores: 2})
      large = assigned(user, project, %{name: "large", memory: 9_000, cores: 16})

      assert Provisioning.for_demand(project.id, demand(memory: 1_000, cores: 1)).id == small.id
      assert Provisioning.for_demand(project.id, demand(memory: 5_000, cores: 1)).id == large.id
      assert Provisioning.for_demand(project.id, demand(memory: 1_000, cores: 8)).id == large.id
      refute Provisioning.for_demand(project.id, demand(memory: 99_000, cores: 1))
    end

    test "a template that does not take this kind is not chosen", %{user: user, project: project} do
      assigned(user, project, %{memory: 9_000, cores: 16, accepts: [:chat]})

      assert Provisioning.for_demand(project.id, demand(kind: :chat))
      refute Provisioning.for_demand(project.id, demand(kind: :workflow))
    end

    # An image labelled older than the job needs would make a machine that joins and cannot take
    # it, every pass, up to `max_workers`. Unlabelled is asked once: its join says.
    test "a template whose image speaks too old a protocol is not chosen", context do
      %{user: user, project: project} = context
      assigned(user, project, %{memory: 9_000, cores: 16, image: "snap-1", image_protocol: 1})
      needs_two = Map.put(demand(), :protocol, 2)

      refute Provisioning.for_demand(project.id, needs_two)
      refute Provisioning.could_ever_hold?(project.id, needs_two)
      assert Provisioning.for_demand(project.id, Map.put(demand(), :protocol, 1))
      assert Provisioning.for_demand(project.id, demand())

      assigned(user, project, %{memory: 9_000, cores: 16, image: "snap-2", image_protocol: nil})
      assert %{image: "snap-2"} = Provisioning.for_demand(project.id, needs_two)
    end

    # **And it comes last.** Read as *yes* and taken in size order, a template on the mark was
    # handed jobs ahead of a concrete template in the same project that would have served them —
    # the protocol filter was what used to remove it, and order is by size. Both templates here
    # are the same size, and the one on the mark is created first so that name order would pick it.
    test "a template that fits is never passed over for one on the mark", context do
      %{user: user, project: project} = context
      needs_two = Map.put(demand(), :protocol, 2)

      _stale =
        assigned(user, project, %{
          memory: 9_000,
          cores: 16,
          image: "latest",
          resolved_image: "snap-1",
          image_protocol: 1
        })

      fits =
        assigned(user, project, %{memory: 9_000, cores: 16, image: "snap-2", image_protocol: 2})

      assert %{id: id} = Provisioning.for_demand(project.id, needs_two)
      assert id == fits.id
    end

    # **A template on the mark is the exception, and it is the mark's one dead case otherwise.**
    # What such a template stores is its *old* snapshot's protocol, and the gate may not ask the
    # driver — so filtering on it kept the template out of every demand its old snapshot was too
    # old for, and the create attempt that would have resolved it onto the newly marked snapshot
    # never ran. Raising the protocol is why an operator builds an image.
    test "a template on the mark is not held to the protocol its old snapshot spoke", context do
      %{user: user, project: project} = context
      needs_two = Map.put(demand(), :protocol, 2)

      following =
        assigned(user, project, %{
          memory: 9_000,
          cores: 16,
          image: "latest",
          resolved_image: "snap-1",
          image_protocol: 1
        })

      assert %{id: id} = Provisioning.for_demand(project.id, needs_two)
      assert id == following.id
      assert Provisioning.could_ever_hold?(project.id, needs_two)
    end

    # The distinction the design insists on: does not fit *now* is a queue, and could never fit
    # is a ticket that sticks. Reading the second as the first queues a job for ever.
    test "could-never-fit is a different answer from does-not-fit-now", context do
      %{user: user, project: project} = context
      assigned(user, project, %{memory: 4_000, cores: 4})

      assert Provisioning.could_ever_hold?(project.id, demand(memory: 4_000, cores: 4))
      refute Provisioning.could_ever_hold?(project.id, demand(memory: 4_001, cores: 4))
      refute Provisioning.could_ever_hold?(project.id, demand(memory: 4_000, cores: 5))
    end

    test "a project with nothing assigned has nothing to choose from", %{project: project} do
      assert Provisioning.for_project(project.id) == []
      refute Provisioning.for_demand(project.id, demand())
      refute Provisioning.could_ever_hold?(project.id, demand())
    end
  end

  defp create_template(user, attrs) do
    Provisioning.create_template(
      user,
      Enum.into(attrs, %{
        name: "t-#{System.unique_integer([:positive])}",
        provider: "fake",
        memory: 8_000,
        cores: 4,
        max_workers: 1
      })
    )
  end

  defp assigned(user, project, attrs) do
    {:ok, template} = create_template(user, attrs)
    {:ok, _} = Provisioning.assign(user, template.id, project.id)
    template
  end

  defp demand(opts \\ []) do
    %{
      kind: Keyword.get(opts, :kind, :workflow),
      memory: Keyword.get(opts, :memory, 1),
      cores: Keyword.get(opts, :cores, 1)
    }
  end

  defp project_attrs do
    n = System.unique_integer([:positive])

    %{
      name: "proj-#{n}",
      repo_path: Path.join(System.tmp_dir!(), "#{System.pid()}-forge-prov-#{n}.git")
    }
  end

  describe "a template that cannot make a working machine" do
    setup do
      user = Forge.AccountsFixtures.user_fixture()

      {:ok, template} =
        Provisioning.create_template(user, %{
          name: "t-#{System.unique_integer([:positive])}",
          provider: "fake",
          memory: 8_000,
          cores: 4,
          max_workers: 1
        })

      %{user: user, template: template}
    end

    test "counts its failures and keeps the last reason", %{template: template} do
      :ok = Provisioning.failed(template.id, "no Hetzner image configured")

      reloaded = Provisioning.template(template.user_id |> user(), template.id)
      assert reloaded.failures == 1
      assert reloaded.last_error == "no Hetzner image configured"
    end

    # Derived from the counter rather than stored beside it: a flag and a count are two facts
    # about one thing, and the day they disagree there is no way to say which is true.
    test "is disabled at the limit and not before", %{template: template} do
      for n <- 1..(Provisioning.failure_limit() - 1) do
        :ok = Provisioning.failed(template.id, "nope")
        refute Provisioning.disabled?(reload(template)), "disabled after #{n}"
      end

      :ok = Provisioning.failed(template.id, "nope")
      assert Provisioning.disabled?(reload(template))
    end

    # Consecutive, not cumulative: a template that has made a hundred good machines should not
    # be disabled by three bad ones spread across a year.
    test "a machine that works clears the count", %{template: template} do
      :ok = Provisioning.failed(template.id, "nope")
      :ok = Provisioning.failed(template.id, "nope")
      # Below the limit it was never out of service, so nothing has arrived.
      refute Provisioning.succeeded(template.id, template.image)

      assert reload(template).failures == 0
      assert reload(template).last_error == nil

      :ok = Provisioning.failed(template.id, "nope")
      refute Provisioning.disabled?(reload(template))
    end

    test "enabling it puts it back and is the owner's alone", %{user: user, template: template} do
      for _ <- 1..Provisioning.failure_limit(), do: Provisioning.failed(template.id, "nope")
      assert Provisioning.disabled?(reload(template))

      stranger = Forge.AccountsFixtures.user_fixture()
      assert {:error, :not_found} = Provisioning.enable(stranger, template.id)
      assert Provisioning.disabled?(reload(template))

      assert {:ok, _template} = Provisioning.enable(user, template.id)
      refute Provisioning.disabled?(reload(template))
      assert reload(template).last_error == nil
    end

    # The gate skips it; the page does not. A template nobody can see is one nobody can enable.
    test "a disabled one leaves the gate but not the list", %{user: user, template: template} do
      {:ok, project} =
        Forge.Projects.register(
          %{
            name: "p-#{System.unique_integer([:positive])}",
            repo_path:
              Path.join(
                System.tmp_dir!(),
                "#{System.pid()}-forge-pt-#{System.unique_integer([:positive])}.git"
              )
          },
          user
        )

      {:ok, _} = Provisioning.assign(user, template.id, project.id)
      demand = %{kind: :workflow, memory: 1, cores: 1}

      assert Provisioning.for_demand(project.id, demand)
      assert Provisioning.could_ever_hold?(project.id, demand)

      for _ <- 1..Provisioning.failure_limit(), do: Provisioning.failed(template.id, "nope")

      refute Provisioning.for_demand(project.id, demand)
      refute Provisioning.could_ever_hold?(project.id, demand)
      assert [_still_listed] = Provisioning.for_project(project.id)
    end

    defp reload(template), do: Forge.Repo.get!(Forge.Provisioning.Template, template.id)
    defp user(id), do: Forge.Repo.get!(Forge.Accounts.User, id)
  end
end
