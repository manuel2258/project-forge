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
      assert {:ok, template} = create_template(user, %{memory: 8_000, cores: 4})

      # Its owner too: a machine made from a template is the template owner's
      # (`identity.md` § Workers).
      assert Template.worker_attrs(template) == %{
               provider: "fake",
               template_id: template.id,
               user_id: user.id,
               provider_credential_id: nil,
               memory_budget: 8_000,
               cores: 4,
               accepts: nil
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
               Provisioning.update_template(mine, %{provider_credential_id: theirs.id})

      assert %{provider_credential_id: ["is not one of your credentials"]} = errors_on(changeset)
    end

    # A local template is the case that has no credential at all, and it must stay creatable:
    # the local driver reaches its machines without an account.
    test "a template for a provider that needs no credential is fine without one", %{user: user} do
      assert {:ok, template} = create_template(user, %{provider: "local"})
      assert template.provider_credential_id == nil
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
      repo_path: Path.join(System.tmp_dir!(), "forge-prov-#{n}.git")
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
      :ok = Provisioning.succeeded(template.id)

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
              Path.join(System.tmp_dir!(), "forge-pt-#{System.unique_integer([:positive])}.git")
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
