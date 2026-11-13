defmodule ForgeWeb.ProjectSettingsDefaultsTest do
  @moduledoc """
  The project's model and effort on its settings page (`docs/design/ui.md` § Model and effort,
  `9g`): one form, one Save, both written or neither; the model's options are the project's
  pool's and the connected workers' aliases; the effort a switch of the levels the workers offer,
  or a box while none does; and beside *the machine's*, what it was last observed to be.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Forge.ForgeFixtures,
    only: [
      credential_fixture: 2,
      job_fixture: 1,
      member_fixture: 2,
      pool!: 2,
      project_fixture: 0,
      ticket_fixture: 1
    ]

  import Forge.SettingsFixtures

  alias Forge.{Projects, Workers}

  setup %{conn: conn} do
    project = project_fixture()
    admin = member_fixture(project, :admin)
    %{conn: log_in_user(conn, admin), admin: admin, project: project}
  end

  defp agent(conn, project), do: live(conn, ~p"/projects/#{project.name}/settings?section=agent")

  defp save(view, params),
    do: view |> form("#defaults-form", %{"project" => params}) |> render_submit()

  defp connected_worker(offer) do
    {:ok, worker, _token} = Workers.create(%{provider: "fake"})
    {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "harness" => offer})
    worker
  end

  test "one Save writes both, and says so", %{conn: conn, project: project} do
    {:ok, view, _html} = agent(conn, project)

    html = save(view, %{"model" => "a-model-no-worker-has", "effort" => "max"})

    assert %{model: "a-model-no-worker-has", effort: "max"} = Projects.get!(project.id)
    assert html =~ "Saved the agent&#39;s defaults."
    assert has_element?(view, "#section-agent", "model: a-model-no-worker-has · effort: max")
  end

  test "one Save clears both", %{conn: conn, project: project} do
    {:ok, project} = Projects.set_defaults(project, %{model: "opus", effort: "high"})
    {:ok, view, _html} = agent(conn, project)

    save(view, %{"model" => "", "effort" => ""})

    assert %{model: nil, effort: nil} = Projects.get!(project.id)
  end

  # Both or neither: a value the changeset refuses leaves the other dial as it was, and the error
  # is drawn under the form the person pressed Save on.
  test "a refused value saves nothing and says so under the form", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, project} = Projects.set_defaults(project, %{model: "haiku", effort: "low"})
    {:ok, view, _html} = agent(conn, project)

    html =
      render_submit(view, "defaults", %{"project" => %{"model" => "opus", "effort" => ["x"]}})

    assert html =~ "That was not saved, and no setting changed."
    assert has_element?(view, "#defaults-form #defaults-error")
    assert %{model: "haiku", effort: "low"} = Projects.get!(project.id)
  end

  test "a hand-sent event naming one dial leaves the other alone", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, project} = Projects.set_defaults(project, %{model: "haiku", effort: "low"})
    {:ok, view, _html} = agent(conn, project)

    render_submit(view, "defaults", %{"project" => %{"effort" => "max"}})

    assert %{model: "haiku", effort: "max"} = Projects.get!(project.id)
  end

  # The form carries an id and a `phx-change`, and the change is held: what a rejoin replays is
  # drawn back, and Discard is what puts the stored values back.
  test "what was typed is held, and Discard puts the stored values back", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, project} = Projects.set_defaults(project, %{model: "haiku"})
    {:ok, view, _html} = agent(conn, project)

    # No worker offers a level, so the effort is a box.
    view
    |> form("#defaults-form", %{"project" => %{"model" => "", "effort" => "half-typed"}})
    |> render_change()

    assert has_element?(view, ~s(#project_effort[value=half-typed]))
    refute has_element?(view, ~s(select#project_model option[value=haiku][selected]))

    view |> element("#defaults-form button", "Discard") |> render_click()

    refute has_element?(view, ~s(#project_effort[value=half-typed]))
    assert has_element?(view, ~s(select#project_model option[value=haiku][selected]))
    assert %{model: "haiku", effort: nil} = Projects.get!(project.id)
  end

  test "a member is not offered the form and is refused the event", %{project: project} do
    plain = member_fixture(project, :member)
    {:ok, view, _html} = agent(log_in_user(build_conn(), plain), project)

    refute has_element?(view, "#defaults-form")

    render_submit(view, "defaults", %{"project" => %{"model" => "evil-model", "effort" => "max"}})

    assert %{model: nil, effort: nil} = Projects.get!(project.id)
  end

  describe "the model" do
    # The models are this project's pool's — the accounts its jobs will actually run on — and not
    # some other project's (`docs/design/credentials.md` § Checked on save).
    test "is a dropdown of what this project's credentials may use", ctx do
      %{conn: conn, project: project} = ctx
      owner = Forge.AccountsFixtures.user_fixture()
      pool!(project, credential_fixture(owner, models: [%{"id" => "claude-sonnet-5"}]))

      elsewhere = project_fixture()
      pool!(elsewhere, credential_fixture(owner, models: [%{"id" => "not-this-projects"}]))

      {:ok, view, _html} = agent(conn, project)

      assert has_element?(view, ~s(select#project_model option[value="claude-sonnet-5"]))
      refute has_element?(view, ~s(select#project_model option[value="not-this-projects"]))

      save(view, %{"model" => "claude-sonnet-5"})
      assert Projects.get!(project.id).model == "claude-sonnet-5"
    end

    # The worker holding it may be asleep rather than gone, and a form that silently dropped it
    # would change a setting nobody touched — docs/design/workflow-grammar-v1.md § Model.
    test "a stored model nothing offers stays selected and survives a save", ctx do
      %{conn: conn, project: project} = ctx
      {:ok, project} = Projects.set_model(project, "a-model-no-worker-has")
      connected_worker(%{"aliases" => ["opus"], "efforts" => ~w(low high)})

      {:ok, view, _html} = agent(conn, project)

      assert has_element?(
               view,
               ~s(select#project_model option[value="a-model-no-worker-has"][selected])
             )

      view |> form("#defaults-form") |> render_submit()
      assert Projects.get!(project.id).model == "a-model-no-worker-has"
    end

    test "names what the machine's was last observed to be", ctx do
      %{conn: conn, project: project} = ctx
      ticket = ticket_fixture(%{project: project})
      harness_started!(job_fixture(%{ticket: ticket}), "claude-sonnet-4-5")

      {:ok, view, _html} = agent(conn, project)

      assert has_element?(view, "#model-observed", "last observed claude-sonnet-4-5")
    end

    # Another project's harness says nothing about this one's machine's model, and nothing is
    # claimed when nothing was seen.
    test "names nothing when nothing of this project's was observed", ctx do
      %{conn: conn, project: project} = ctx
      elsewhere = ticket_fixture(%{project: project_fixture()})
      harness_started!(job_fixture(%{ticket: elsewhere}), "claude-theirs")

      {:ok, view, html} = agent(conn, project)

      refute has_element?(view, "#model-observed")
      refute html =~ "claude-theirs"
    end
  end

  describe "the effort" do
    # A box because no worker is connected to offer a level, so a project can be configured before
    # a machine exists. `docs/design/workflow-grammar-v1.md` § Effort says why nothing checks it.
    test "is a box that saves what is typed while nothing is offered", ctx do
      %{conn: conn, project: project} = ctx
      {:ok, view, html} = agent(conn, project)

      assert has_element?(view, ~s(input#project_effort[type=text]))
      assert html =~ "No connected worker offers a level"

      save(view, %{"effort" => "xhigh"})
      assert Projects.get!(project.id).effort == "xhigh"
    end

    test "is a switch of the levels the workers offer, the machine's first", ctx do
      %{conn: conn, project: project} = ctx
      connected_worker(%{"efforts" => ~w(low high)})
      {:ok, project} = Projects.set_effort(project, "low")

      {:ok, view, _html} = agent(conn, project)

      refute has_element?(view, ~s(input#project_effort[type=text]))

      assert has_element?(
               view,
               ~s(#project_effort.ui-seg input[name="project[effort]"][value=""])
             )

      assert has_element?(view, ~s(#project_effort input[value=low][checked]))
      refute has_element?(view, ~s(#project_effort input[value=high][checked]))

      save(view, %{"effort" => "high"})
      assert Projects.get!(project.id).effort == "high"

      save(view, %{"effort" => ""})
      assert is_nil(Projects.get!(project.id).effort)
    end

    # Four fit a switch at 412px; more become rows.
    test "is rows when the levels do not fit a switch", ctx do
      %{conn: conn, project: project} = ctx
      connected_worker(%{"efforts" => ~w(low medium high max)})

      {:ok, view, _html} = agent(conn, project)

      refute has_element?(view, "#project_effort.ui-seg")
      assert has_element?(view, ~s(#project_effort label.ui-choice input[value=max]))
      assert has_element?(view, ~s(#project_effort input[value=""][checked]))
    end

    # The worker with the level may be asleep, or a later harness may have dropped it. A form that
    # dropped it would change a setting nobody touched, so saving unchanged must keep it.
    test "a stored level nothing offers stays checked, marked set, and survives a save", ctx do
      %{conn: conn, project: project} = ctx
      connected_worker(%{"efforts" => ~w(low high)})
      {:ok, project} = Projects.set_effort(project, "turbo")

      {:ok, view, _html} = agent(conn, project)

      assert has_element?(view, ~s(#project_effort label), "turbo · set")
      assert has_element?(view, ~s(#project_effort input[value=turbo][checked]))

      view |> form("#defaults-form") |> render_submit()
      assert Projects.get!(project.id).effort == "turbo"
    end

    test "an offered level is not also drawn as set", %{conn: conn, project: project} do
      connected_worker(%{"efforts" => ~w(low high)})
      {:ok, project} = Projects.set_effort(project, "high")

      {:ok, view, html} = agent(conn, project)

      assert has_element?(view, ~s(#project_effort input[value=high][checked]))
      refute html =~ "high · set"
    end

    # The switch is the browser's protection and not the platform's: a harness newer than the
    # workers may take a level they never reported.
    test "a level nobody offers is still stored", %{conn: conn, project: project} do
      connected_worker(%{"efforts" => ~w(low high)})
      {:ok, view, _html} = agent(conn, project)

      render_submit(view, "defaults", %{"project" => %{"effort" => "ultra"}})

      assert Projects.get!(project.id).effort == "ultra"
    end

    test "a level with markup in it is shown as text", %{conn: conn, project: project} do
      connected_worker(%{"efforts" => ["<b>x</b>"]})

      {:ok, view, html} = agent(conn, project)

      assert has_element?(view, ~s(#project_effort label), "<b>x</b>")
      refute has_element?(view, ~s(#project_effort b))
      assert html =~ "&lt;b&gt;x&lt;/b&gt;"
    end
  end
end
