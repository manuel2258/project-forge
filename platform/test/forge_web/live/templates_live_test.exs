defmodule ForgeWeb.TemplatesLiveTest do
  @moduledoc """
  The page where a machine's recipe and its bill are decided.

  The assertions that matter are the ones about *whose*: a person sees their own credentials
  and their own templates, and the assignment they can make is bounded by both owning the
  template and being in the project (`docs/design/provisioning.md` § Whose account).
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Forge.Provisioning

  setup :register_and_log_in_user

  # The template form asks for nothing until an account is named, so a suite about the *rest*
  # of the form starts with a credential the way an operator would have to.
  setup %{user: user} do
    {:ok, credential} =
      Provisioning.create_credential(user, %{
        name: "fake-acct",
        provider: "fake",
        secret: %{"token" => "t"}
      })

    %{credential: credential}
  end

  # The options of the one select whose name matches, as rendered.
  defp options_of(html, field) do
    html
    |> String.split(~r/<select[^>]*#{Regex.escape(field)}[^>]*>/, parts: 2)
    |> List.last()
    |> String.split("</select>", parts: 2)
    |> List.first()
  end

  defp project_for(user) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Forge.Projects.register(
        %{
          name: "proj-#{n}",
          repo_path: Path.join(System.tmp_dir!(), "#{System.pid()}-forge-tl-#{n}.git")
        },
        user
      )

    project
  end

  defp template_for(user, attrs \\ %{}) do
    {:ok, template} =
      Provisioning.create_template(
        user,
        Enum.into(attrs, %{
          name: "t-#{System.unique_integer([:positive])}",
          provider: "fake",
          memory: 8 * 1024 * 1024 * 1024,
          cores: 4,
          max_workers: 2
        })
      )

    template
  end

  # **The empty state is the feature.** With no node fallback this is the whole reason a new
  # node runs nothing, and it used to say the opposite — that machines would be made from the
  # node's configured provider, which is what silently made five `local` machines on a node
  # whose Hetzner template was sitting unassigned (`provisioning.md` § Whose account).
  test "an empty page says that without a template nothing runs", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/templates")

    assert html =~ "None yet, so nothing runs"
    refute html =~ "this node&#39;s configured provider"
  end

  test "a credential is added and its secret never reaches the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    html =
      view
      |> form("#credential-form",
        credential: %{name: "second-account", provider: "fake", token: "sekrit"}
      )
      |> render_submit()

    assert html =~ "second-account"
    refute html =~ "sekrit"
  end

  # A `phx-change` form sends every field on every keystroke, and the handler used to assign all
  # of it: the token sat in this LiveView's state, and `<.input>` rendered it back into the page
  # as the password field's value.
  test "a token being typed is in neither the page nor the state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    html =
      view
      |> form("#credential-form",
        credential: %{name: "typing", provider: "fake", token: "half-typed-sekrit"}
      )
      |> render_change()

    refute html =~ "half-typed-sekrit"
    refute inspect(:sys.get_state(view.pid), limit: :infinity) =~ "half-typed-sekrit"
  end

  # The bug this was found as: the credential form offered `local`, which has no fields, so the
  # form had nothing to fill in and the changeset then refused the empty secret. A provider
  # reached without an account has no credential to make, and the form should not pretend
  # otherwise.
  test "a provider that needs no credential is not offered one", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/templates")

    assert [_form] = Regex.scan(~r/id="credential-form"/, html)

    options = options_of(html, "credential[provider]")

    assert options =~ "fake"
    assert options =~ "hetzner"
    refute options =~ "local"
  end

  # But a *template* for that provider is exactly the case that carries no credential, and it
  # has to stay creatable.
  test "a template for a provider that needs no credential is creatable", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    # Choosing it is what takes the credential select away, and with it the credential of the
    # provider the form was on — a local template carries none.
    view |> form("#template-form", template: %{provider: "local"}) |> render_change()

    html =
      view
      |> form("#template-form",
        template: %{
          name: "here",
          provider: "local",
          memory: "4GiB",
          cores: "2",
          max_workers: "1"
        }
      )
      |> render_submit()

    assert html =~ "here"
    assert html =~ "0 of 1 made"
  end

  test "a template is created and shows what a machine from it will be", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    html =
      view
      |> form("#template-form",
        template: %{
          name: "build",
          provider: "fake",
          memory: "8GiB",
          cores: "4",
          max_workers: "3"
        }
      )
      |> render_submit()

    assert html =~ "build"
    assert html =~ "8.0 GiB"
    assert html =~ "4 cores"
    assert html =~ "0 of 3 made"
    # Nothing ticked means any kind, the same reading a worker that reported none gets.
    assert html =~ "any kind"
  end

  # The units the grammar accepts, so an operator who writes `8GiB` in a workflow writes the
  # same thing here. A field this rejects must not silently become a template with no memory.
  test "a memory size that is not one is refused rather than stored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    html =
      view
      |> form("#template-form",
        template: %{name: "bad", provider: "fake", memory: "lots", cores: "4", max_workers: "1"}
      )
      |> render_submit()

    # The *message* matters, not just the refusal: read as zero rather than as nothing said,
    # this would complain that the memory must be greater than zero — which sends somebody
    # looking for a number they never typed instead of at the word they did.
    assert html =~ "memory can&#39;t be blank"
    refute html =~ "0 of 1 made"
  end

  # A machine smaller than the least one job can run in makes nothing anybody can use, and the
  # refusal names the minimum rather than leaving the operator to find it.
  test "a machine smaller than one job is refused, and the minimum is named", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    html =
      view
      |> form("#template-form",
        template: %{
          name: "tiny",
          provider: "fake",
          memory: "256MiB",
          cores: "1",
          max_workers: "1"
        }
      )
      |> render_submit()

    assert html =~ "memory must be at least 512MiB, the least a job can run in"
    refute html =~ "0 of 1 made"

    html =
      view
      |> form("#template-form",
        template: %{
          name: "small",
          provider: "fake",
          memory: "512MiB",
          cores: "1",
          max_workers: "1"
        }
      )
      |> render_submit()

    refute html =~ "must be at least 512MiB"
    assert html =~ "small"
  end

  # And an edit is the same form: shrinking a template below one job is refused, and the stored
  # figure stays.
  test "an edit below the minimum is refused, and the template keeps its memory", %{
    conn: conn,
    user: user
  } do
    template = template_for(user)
    {:ok, view, _html} = live(conn, ~p"/templates")

    view
    |> element(~s(button[phx-click=edit-template][phx-value-id="#{template.id}"]))
    |> render_click()

    html =
      view
      |> form("#edit-template-#{template.id}",
        template: %{name: template.name, memory: "2", cores: "4", max_workers: "2"}
      )
      |> render_submit()

    assert html =~ "memory must be at least 512MiB, the least a job can run in"
    assert Provisioning.template(user, template.id).memory == 8 * 1024 * 1024 * 1024
  end

  test "a template is assigned to a project and taken off again", %{conn: conn, user: user} do
    project = project_for(user)
    template = template_for(user)

    {:ok, view, html} = live(conn, ~p"/templates")
    assert html =~ "never used"

    html =
      view
      |> element("#template-#{template.id} form[phx-submit=assign]")
      |> render_submit(%{"template" => template.id, "project" => project.id})

    assert html =~ project.name
    refute html =~ "never used"

    html =
      view
      |> element("button[phx-click=unassign][phx-value-project=\"#{project.id}\"]")
      |> render_click()

    assert html =~ "never used"
  end

  # The scoping rule on the page rather than in the context: another person's rows are not
  # there to be acted on in the first place.
  test "somebody else's credentials and templates are not shown", %{conn: conn, user: user} do
    other = Forge.AccountsFixtures.user_fixture()
    theirs = template_for(other, %{name: "not-yours"})

    {:ok, _} =
      Provisioning.create_credential(other, %{
        name: "not-your-account",
        provider: "fake",
        secret: %{"token" => "t"}
      })

    {:ok, _view, html} = live(conn, ~p"/templates")

    refute html =~ "not-yours"
    refute html =~ "not-your-account"

    # And still theirs afterwards: the page not showing it is not the only thing stopping it.
    assert Provisioning.template(other, theirs.id)
    assert Provisioning.templates(user) == []
  end

  # A project the caller is not in is refused even when the id is supplied by hand, which is
  # the `handle_event` holding a client-supplied id that `identity.md` § Sequencing records as
  # the shape these holes keep taking.
  test "assigning to a project the caller is not in is refused", %{conn: conn, user: user} do
    elsewhere = project_for(Forge.AccountsFixtures.user_fixture())
    template = template_for(user)

    {:ok, view, _html} = live(conn, ~p"/templates")

    html =
      view
      |> element("#template-#{template.id} form[phx-submit=assign]")
      |> render_submit(%{"template" => template.id, "project" => elsewhere.id})

    assert html =~ "not in that project"
    assert Provisioning.for_project(elsewhere.id) == []
  end

  # A template belonging to somebody else cannot be assigned by supplying its id either.
  test "assigning a template the caller does not own is refused", %{conn: conn, user: user} do
    project = project_for(user)
    mine = template_for(user)
    theirs = template_for(Forge.AccountsFixtures.user_fixture())

    {:ok, view, _html} = live(conn, ~p"/templates")

    view
    |> element("#template-#{mine.id} form[phx-submit=assign]")
    |> render_submit(%{"template" => theirs.id, "project" => project.id})

    assert Provisioning.for_project(project.id) == []
  end

  # What `shapes/1` exists for. The driver's catalogue reaches the form, so an operator picks a
  # machine that exists instead of typing a name that does not — and the platform still never
  # parses the size it hands back (`docs/design/provisioning.md` § Where a machine comes from).
  test "the provider's own machine sizes are offered", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/templates")

    assert html =~ "small — 2.0 GiB, 2 cores"
    assert html =~ "large — 8.0 GiB, 8 cores"
  end

  # The bug this was found as, reported against a running node: the page mounted on a provider
  # that takes a credential with none chosen, asked its driver for a catalogue anyway, and
  # rendered the driver's *no Hetzner credential* twice in red before the operator had touched
  # anything. A catalogue is a question about an account; with no account there is nothing to
  # ask (`docs/design/provisioning.md` § Where a machine comes from).
  test "a provider with no credential of its own is not asked for a catalogue", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    html = view |> form("#template-form", template: %{provider: "hetzner"}) |> render_change()

    refute html =~ "could not read"
    assert html =~ "Add a hetzner credential above"
    # And nothing to fill in or submit, rather than a form that cannot work.
    refute html =~ "Create it"
    refute html =~ "Max machines"
  end

  # The other half of the same rule: the fields arrive with the account that pays for them, and
  # leave with it. The credential is chosen for the operator because there is no choosing none.
  test "the rest of the form comes and goes with the credential", %{conn: conn, credential: c} do
    {:ok, view, html} = live(conn, ~p"/templates")
    assert html =~ "small — 2.0 GiB, 2 cores"

    html =
      view
      |> element("button[phx-click=delete-credential][phx-value-id=\"#{c.id}\"]")
      |> render_click()

    refute html =~ "small — 2.0 GiB, 2 cores"
    refute html =~ "Create it"
    assert html =~ "Add a fake credential above"

    html =
      view
      |> form("#credential-form", credential: %{name: "again", provider: "fake", token: "t"})
      |> render_submit()

    assert html =~ "small — 2.0 GiB, 2 cores"
    assert html =~ "Create it"
  end

  # A template that named no credential could only fall back to the node's own token, which is
  # the thing per-user credentials replaced (`docs/design/provisioning.md` § Whose account).
  test "the credential select offers no way to choose none", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/templates")

    options = options_of(html, "template[provider_credential_id]")

    assert options =~ "fake-acct"
    refute options =~ "none"
  end

  # Picking one fills the two numbers that go with it, rather than leaving three figures to be
  # copied off a price list with one of them got wrong.
  test "choosing a size fills the memory and cores that go with it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    html =
      view
      |> form("#template-form", template: %{provider: "fake", size: "large"})
      |> render_change()

    # **The unit, not the byte count.** Filling a field labelled `8GiB` with `8589934592` made
    # the form argue with its own label — and, until `parse_bytes/1` accepted a bare numeric
    # string, submitting what it had written came back as *memory can't be blank*. Reported by
    # an operator against a running node.
    assert html =~ ~s(value="8GiB")
    assert html =~ ~s(value="8")
  end

  # Reported against a running node, from the same session as the crash above: `phx-change`
  # fires on the whole form rather than on the field that moved, so the autofill saw a size it
  # recognised on every event and wrote the shape's memory back over what had been typed. Only
  # a *change* of size fills.
  test "a memory edited by hand survives a change to another field", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    view
    |> form("#template-form", template: %{provider: "fake", size: "large"})
    |> render_change()

    html =
      view
      |> form("#template-form", template: %{memory: "16GiB", name: "typed"})
      |> render_change()

    assert html =~ ~s(value="16GiB")
  end

  # But choosing a different size still fills, which is what the autofill is for.
  test "choosing another size fills the numbers again", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    view
    |> form("#template-form", template: %{provider: "fake", size: "large"})
    |> render_change()

    html =
      view
      |> form("#template-form", template: %{size: "small"})
      |> render_change()

    assert html =~ ~s(value="2GiB")
    assert html =~ ~s(value="2")
  end

  # The round trip end to end: what the autofill writes has to survive being submitted.
  test "a template created from an autofilled size keeps that size", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    view
    |> form("#template-form", template: %{provider: "fake", size: "large"})
    |> render_change()

    view
    |> form("#template-form",
      template: %{name: "autofilled", provider: "fake", size: "large", max_workers: "1"}
    )
    |> render_submit()

    assert [template] = Provisioning.templates(user)
    assert template.memory == 8 * 1024 * 1024 * 1024
    assert template.cores == 8
  end

  # Hetzner has no image upload, so what a template names is a snapshot the operator already
  # made. The form offers what the driver can see rather than asking for an id to be pasted.
  test "the provider's own images are offered", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/templates")

    assert html =~ "forge-worker"
    assert html =~ "the node&#39;s default"
  end

  # **A provider that cannot make a machine without an image is not offered the node's.** There
  # is no node-wide image for Hetzner — the key it used to read is the local driver's qcow2 path
  # — so that option would be a promise the changeset then refuses. The fake stands in, because
  # the real driver's catalogue is a network call.
  describe "a provider that requires an image and a size" do
    setup do
      Forge.Provider.Fake.requiring([:size, :image])
      on_exit(&Forge.Provider.Fake.allow/0)
    end

    test "offers a prompt where the default was", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/templates")

      images = options_of(html, "template[image]")
      assert images =~ ~s(<option value="">choose one</option>)
      refute images =~ "default"
      assert images =~ "forge-worker"

      sizes = options_of(html, "template[size]")
      assert sizes =~ ~s(<option value="">choose one</option>)
      refute sizes =~ "custom"
    end

    # The edit form is the create form's fields with the stored template's provider, and it
    # has to ask the same question of it — or an edit offers the node's default the changeset
    # then refuses, which is the promise the create form stopped making.
    test "the edit form offers a prompt where the default was, too", %{conn: conn, user: user} do
      template = template_for(user, %{size: "small", image: "forge-worker"})

      {:ok, view, _html} = live(conn, ~p"/templates")

      view
      |> element(~s(button[phx-click=edit-template][phx-value-id="#{template.id}"]))
      |> render_click()

      form = view |> element(~s(form#edit-template-#{template.id})) |> render()

      images = options_of(form, "template[image]")
      assert images =~ ~s(<option value="">choose one</option>)
      refute images =~ "default"

      sizes = options_of(form, "template[size]")
      assert sizes =~ ~s(<option value="">choose one</option>)
      refute sizes =~ "custom"
    end

    test "and a template left without one is refused, with the reason", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/templates")

      html =
        view
        |> form("#template-form",
          template: %{name: "bare", size: "large", memory: "4GiB", cores: "2", max_workers: "1"}
        )
        |> render_submit()

      assert html =~ "image can&#39;t be blank"
      assert Provisioning.templates(user) == []
    end
  end

  test "a template records the image it was given", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    view
    |> form("#template-form",
      template: %{
        name: "imaged",
        provider: "fake",
        image: "snapshot-1",
        memory: "4GiB",
        cores: "2",
        max_workers: "1"
      }
    )
    |> render_submit()

    assert [template] = Provisioning.templates(user)
    assert template.image == "snapshot-1"
  end

  # What a snapshot carries, read from its provider labels: the worker build against the one this
  # platform ships with, and the protocol it speaks — or *unlabelled*, which is not guessed at
  # (`docs/design/provisioning.md` § A snapshot that speaks the wrong protocol).
  describe "what a snapshot carries" do
    setup do
      previous = Application.get_env(:forge, Forge.Workers, [])
      on_exit(fn -> Application.put_env(:forge, Forge.Workers, previous) end)

      Application.put_env(
        :forge,
        Forge.Workers,
        Keyword.put(previous, :current_build, "aaaaaaaaaaaa")
      )

      Forge.Provider.Fake.listing([
        %{id: "snap-new", name: "new", build: "aaaaaaaaaaaa", protocol: 1},
        %{id: "snap-old", name: "old", build: "bbbbbbbbbbbb", protocol: 0},
        %{id: "snap-legacy", name: "legacy", build: nil, protocol: nil}
      ])

      on_exit(&Forge.Provider.Fake.allow/0)
      :ok
    end

    test "each image is offered with its build and protocol, or as unlabelled", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/templates")
      options = options_of(html, "template[image]")

      assert options =~ "new · build aaaaaaaaaaaa current · protocol 1"
      assert options =~ "old · build bbbbbbbbbbbb other build · protocol 0"
      assert options =~ "legacy · unlabelled"
    end

    # From the listing the page holds, never from the form: the params are the client's.
    test "a saved template records what its image carries", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/templates")

      view
      |> form("#template-form",
        template: %{
          name: "labelled",
          provider: "fake",
          image: "snap-old",
          memory: "4GiB",
          cores: "2",
          max_workers: "1"
        }
      )
      |> render_submit(%{"template" => %{"image_protocol" => "9", "image_build" => "forged"}})

      assert [template] = Provisioning.templates(user)
      assert {template.image_build, template.image_protocol} == {"bbbbbbbbbbbb", 0}
    end

    # Scoped to each row: the image select above offers the same words for the same snapshots,
    # and a match anywhere on the page would hold with the rows saying nothing.
    test "a template's row says what its image carries", %{conn: conn, user: user} do
      known =
        template_for(user, %{
          name: "known",
          image: "snap-new",
          image_build: "aaaaaaaaaaaa",
          image_protocol: 1
        })

      old = template_for(user, %{name: "old-one", image: "snap-legacy"})

      {:ok, view, _html} = live(conn, ~p"/templates")
      known_row = view |> element("#template-#{known.id}") |> render()
      old_row = view |> element("#template-#{old.id}") |> render()

      assert known_row =~ "build aaaaaaaaaaaa current · protocol 1"
      refute known_row =~ "no machine is made from it"
      assert old_row =~ "unlabelled"
    end

    # Moving a template onto another snapshot takes that snapshot's labels. Kept from the old one,
    # a template moved off an image the platform refuses would go on refusing, and one moved onto a
    # bad unlabelled image would keep the good image's protocol.
    test "an edit onto another image takes that image's labels", %{conn: conn, user: user} do
      template =
        template_for(user, %{
          name: "moving",
          image: "snap-old",
          image_build: "bbbbbbbbbbbb",
          image_protocol: 0
        })

      {:ok, view, _html} = live(conn, ~p"/templates")

      view
      |> element(~s(button[phx-click=edit-template][phx-value-id="#{template.id}"]))
      |> render_click()

      view
      |> form("#edit-template-#{template.id}",
        template: %{
          name: "moving",
          provider: "fake",
          image: "snap-new",
          memory: "8GiB",
          cores: "4",
          max_workers: "2"
        }
      )
      |> render_submit()

      saved = Forge.Repo.get!(Forge.Provisioning.Template, template.id)

      assert {saved.image, saved.image_build, saved.image_protocol} ==
               {"snap-new", "aaaaaaaaaaaa", 1}
    end

    # Once a job has asked, the failures line carries the same sentence as its last error; the
    # row says it once.
    test "a template that has failed for its image says so once", %{conn: conn, user: user} do
      too_new = ForgeCore.WorkerProtocol.current() + 1
      template = template_for(user, %{name: "failed", image: "snap-x", image_protocol: too_new})
      :ok = Provisioning.failed(template.id, Provisioning.image_refusal(template))

      {:ok, view, _html} = live(conn, ~p"/templates")
      row = view |> element("#template-#{template.id}") |> render()

      assert length(String.split(row, "its image speaks worker protocol")) == 2
    end

    # Said on the row before any job asks, not only in the failures that begin once one does.
    test "a template whose image this platform cannot talk to says so", %{conn: conn, user: user} do
      too_new = ForgeCore.WorkerProtocol.current() + 1
      template = template_for(user, %{name: "too-new", image: "snap-x", image_protocol: too_new})

      {:ok, view, _html} = live(conn, ~p"/templates")

      assert view |> element("#template-#{template.id}") |> render() =~
               "its image speaks worker protocol #{too_new}, and this platform accepts " <>
                 "#{ForgeCore.WorkerProtocol.range()}: no machine is made from it"
    end
  end

  # A node built outside Nix knows no build of its own, so a snapshot's build is shown without a
  # hint rather than with an invented one.
  test "a snapshot's build has no hint on a node that knows no build", %{conn: conn} do
    Forge.Provider.Fake.listing([
      %{id: "snap-new", name: "new", build: "aaaaaaaaaaaa", protocol: 1}
    ])

    on_exit(&Forge.Provider.Fake.allow/0)

    {:ok, _view, html} = live(conn, ~p"/templates")
    options = options_of(html, "template[image]")

    assert options =~ "new · build aaaaaaaaaaaa · protocol 1"
    refute options =~ "current"
    refute options =~ "other build"
  end

  # For a provider that does not require one, no image is saved as none and left to the driver
  # — the local one boots its host's image whatever a template says. A provider that does
  # require one is the describe above.
  test "a template that names none leaves it to the driver", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/templates")

    view
    |> form("#template-form",
      template: %{name: "bare", provider: "fake", memory: "4GiB", cores: "2", max_workers: "1"}
    )
    |> render_submit()

    assert [template] = Provisioning.templates(user)
    assert template.image == nil
  end

  test "a template is removed", %{conn: conn, user: user} do
    template = template_for(user, %{name: "goes-away"})

    {:ok, view, html} = live(conn, ~p"/templates")
    assert html =~ "goes-away"

    html =
      view
      |> element("button[phx-click=delete-template][phx-value-id=\"#{template.id}\"]")
      |> render_click()

    refute html =~ "goes-away"
    assert Provisioning.templates(user) == []
  end

  describe "editing one" do
    # `update_template/2` has existed since templates did and nothing could reach it. Safe
    # because values are copied at creation, so an edit never reaches a machine that exists.
    test "a template's fields are changed in place", %{conn: conn, user: user} do
      template = template_for(user, %{name: "before", memory: 8 * 1024 * 1024 * 1024, cores: 4})

      {:ok, view, _html} = live(conn, ~p"/templates")

      view
      |> element(~s(button[phx-click=edit-template][phx-value-id="#{template.id}"]))
      |> render_click()

      # Filled from the template, in the units a person types rather than the byte count.
      assert view |> element(~s(form#edit-template-#{template.id})) |> render() =~
               ~s(value="8GiB")

      view
      |> form("#edit-template-#{template.id}",
        template: %{
          name: "after",
          provider: "fake",
          memory: "16GiB",
          cores: "8",
          max_workers: "2"
        }
      )
      |> render_submit()

      assert [saved] = Provisioning.templates(user)
      assert saved.id == template.id
      assert saved.name == "after"
      assert saved.memory == 16 * 1024 * 1024 * 1024
      assert saved.cores == 8
    end

    # The id arrives from the client, so being able to see the page is not what decides this.
    test "a template the caller does not own cannot be edited", %{conn: conn, user: user} do
      theirs = template_for(Forge.AccountsFixtures.user_fixture(), %{name: "not-yours"})
      mine = template_for(user, %{name: "mine"})

      {:ok, view, _html} = live(conn, ~p"/templates")

      render_click(view, "edit-template", %{"id" => theirs.id})
      refute has_element?(view, ~s(form#edit-template-#{theirs.id}))

      # And a save aimed at it does nothing, even with an edit of your own open.
      view
      |> element(~s(button[phx-click=edit-template][phx-value-id="#{mine.id}"]))
      |> render_click()

      render_submit(view, "save-template", %{
        "template" => %{"name" => "stolen", "provider" => "fake"}
      })

      assert Provisioning.template(Forge.AccountsFixtures.user_fixture(), theirs.id) == nil
      assert Forge.Repo.get!(Provisioning.Template, theirs.id).name == "not-yours"
    end

    # One catalogue, keyed on the provider being edited, so only one form may be open.
    test "the create form steps aside while a template is being edited", %{conn: conn, user: user} do
      template = template_for(user)

      {:ok, view, _html} = live(conn, ~p"/templates")
      assert has_element?(view, "#template-form")

      view
      |> element(~s(button[phx-click=edit-template][phx-value-id="#{template.id}"]))
      |> render_click()

      refute has_element?(view, "#template-form")

      view |> element(~s(button[phx-click=cancel-edit])) |> render_click()
      assert has_element?(view, "#template-form")
    end
  end

  describe "a template that keeps failing" do
    setup %{user: user} do
      template = template_for(user, %{name: "broken"})
      %{template: template}
    end

    test "its failures are shown before it is disabled", %{conn: conn, template: template} do
      :ok = Provisioning.failed(template.id, "no Hetzner image configured")

      {:ok, _view, html} = live(conn, ~p"/templates")

      assert html =~ "1 failed attempt"
      assert html =~ "no Hetzner image configured"
      refute html =~ "Disabled"
    end

    test "at the limit it is flagged and offers a way back", %{conn: conn, template: template} do
      for _ <- 1..Provisioning.failure_limit(), do: Provisioning.failed(template.id, "nope")

      {:ok, view, html} = live(conn, ~p"/templates")

      assert html =~ "Disabled"
      assert html =~ "out of service until you enable it"

      view
      |> element(~s(button[phx-click=enable-template][phx-value-id="#{template.id}"]))
      |> render_click()

      refute Provisioning.disabled?(Forge.Repo.get!(Provisioning.Template, template.id))
      refute render(view) =~ "Disabled"
    end

    # Enabling somebody else's is refused where every other client-supplied id is.
    test "enabling a template the caller does not own is refused", %{conn: conn, user: user} do
      theirs = template_for(Forge.AccountsFixtures.user_fixture(), %{name: "not-yours"})
      for _ <- 1..Provisioning.failure_limit(), do: Provisioning.failed(theirs.id, "nope")
      _mine = template_for(user)

      {:ok, view, _html} = live(conn, ~p"/templates")
      render_click(view, "enable-template", %{"id" => theirs.id})

      assert Provisioning.disabled?(Forge.Repo.get!(Provisioning.Template, theirs.id))
    end
  end
end
