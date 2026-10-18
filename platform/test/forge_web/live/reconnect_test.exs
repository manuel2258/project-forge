defmodule ForgeWeb.ReconnectTest do
  @moduledoc """
  A socket that drops while the page sits idle must not take what was typed with it
  (`docs/design/ui.md` § A reconnect is not a reload).

  **What a test here reaches, and what it cannot.** The recovery is the client's: on a rejoin
  LiveView copies every `form[phx-change]` that has an `id` out of the live DOM and re-pushes
  that form's change event with what was typed, before it applies the new mount's render
  (`deps/phoenix_live_view/assets/js/phoenix_live_view/view.ts`, `maybeRecoverForms`). No ExUnit
  test can drive a browser, so the contract is pinned in the two halves that both have to hold:

  - the **shape**, which decides whether the client replays anything at all — the box is in a
    form carrying an `id` and a `phx-change`;
  - the **handler**, which decides whether the replay is worth anything — the page holds what
    the replayed change carried, and draws the box from it.

  `render_change/3` on a form is exactly the event the client replays, so the second half is
  driven for real. The first is asserted on the markup, because the markup is what the client
  reads to decide whether to replay.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Jobs, Projects, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "rc-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    Process.put(:worker, Forge.FakeWorker.connect())
    %{project: project}
  end

  defp run_pending(ticket_id, scenario, doc) do
    [job] = Enum.filter(Jobs.for_ticket(ticket_id), &(&1.status == :pending))
    {:ok, job} = Forge.FakeWorker.run(job, Process.get(:worker), scenario, doc: doc)
    job
  end

  defp awaiting_approval(project, user) do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    run_pending(ticket.id, "success", "refinement.md")
    ticket
  end

  # Every box a person types into, and the form the client would have to replay to put it back.
  # A textarea outside any form is counted too, because the client cannot replay one at all.
  defp boxes(html) do
    doc = Floki.parse_document!(html)
    in_forms = for form <- Floki.find(doc, "form"), box <- typed_into(form), do: {form, box}

    loose = length(typed_into(doc)) - length(in_forms)
    {in_forms, loose}
  end

  defp typed_into(node), do: Floki.find(node, "textarea, input[type=text]")

  # The shape half: if this fails, nothing the handler does matters, because the client never
  # sends the event that would reach it.
  defp assert_recoverable(html, where) do
    {in_forms, loose} = boxes(html)

    assert loose == 0, "#{where}: #{loose} box(es) in no form at all, which nothing can replay"
    assert in_forms != [], "#{where}: no box to check — the surface did not draw what it should"

    for {form, box} <- in_forms do
      name = Floki.attribute(box, "name")

      assert Floki.attribute(form, "id") != [],
             "#{where}: the form holding #{inspect(name)} has no id, so it is never replayed"

      assert Floki.attribute(form, "phx-change") != [],
             "#{where}: the form holding #{inspect(name)} has no phx-change, so it is never " <>
               "copied for replay"
    end
  end

  describe "the shape a rejoin needs" do
    test "holds on the queue, with an approval and a question waiting", %{
      conn: conn,
      user: user,
      project: project
    } do
      awaiting_approval(project, user)

      {:ok, asking} = Tickets.admit(project, %{title: "Ask me"}, {:user, user.id})
      run_pending(asking.id, "blocking", "refinement.md")

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Approving pins"
      assert_recoverable(html, "the queue")
    end

    test "holds on a ticket's Decide", %{conn: conn, user: user, project: project} do
      ticket = awaiting_approval(project, user)

      {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide")
      assert html =~ "Approving pins"
      assert_recoverable(html, "a ticket's Decide")
    end

    test "holds on a project's proposals", %{conn: conn, user: user, project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
      [job | _] = Jobs.for_ticket(ticket.id)

      Forge.ForgeFixtures.proposal_fixture(%{
        job: job,
        title: "Extract the score table",
        body: "The plan assumes a module that is not there."
      })

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")
      assert html =~ "Extract the score table"
      assert_recoverable(html, "a project's proposals")
    end
  end

  describe "the handler a rejoin's replay lands in" do
    # This is the event the client re-pushes on a rejoin, against a view that has just mounted
    # and holds nothing — which is the whole of what a rejoin is on the server's side.
    test "puts an approval's comment back", %{conn: conn, user: user, project: project} do
      ticket = awaiting_approval(project, user)
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#approve-#{ticket.id}", %{"comment" => "pinned at the wrong one"})
      |> render_change()

      assert view |> element("#approval-#{ticket.id} textarea[name=comment]") |> render() =~
               "pinned at the wrong one"
    end

    test "puts a proposal's comment and its chosen type back", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
      [job | _] = Jobs.for_ticket(ticket.id)

      version =
        Forge.ForgeFixtures.proposal_fixture(%{
          job: job,
          title: "Extract the score table",
          body: "The plan assumes a module that is not there."
        })

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      view
      |> form("#propose-#{version.id}", %{"comment" => "worth doing after the release"})
      |> render_change()

      assert view |> element("#proposal-comment-#{version.id}") |> render() =~
               "worth doing after the release"
    end
  end

  # The select beside a proposal's comment, which a rejoin has to put back too — drawn straight,
  # because the pages that offer it are the ones whose project has types.
  describe "a proposal's chosen type" do
    defp proposal_html(drafts) do
      render_component(&ForgeWeb.Operator.Components.proposals/1,
        proposals: [
          %{
            title: "Extract the score table",
            file: "proposal-score-table.md",
            body: "It is a day's work.",
            version_id: "v1",
            project: "game",
            ticket_number: 7,
            readable: true,
            suggested: "chore"
          }
        ],
        types: [%{name: "bug", parses: true}, %{name: "chore", parses: true}],
        drafts: drafts
      )
    end

    defp selected(html) do
      html
      |> Floki.parse_fragment!()
      |> Floki.find("select[name=ticket_type] option[selected]")
      |> Floki.attribute("value")
    end

    test "is the suggestion until somebody chooses" do
      assert selected(proposal_html(%{})) == ["chore"]
    end

    test "is what a replayed change carried, over the suggestion" do
      assert selected(proposal_html(%{"propose-v1" => %{"ticket_type" => "bug"}})) == ["bug"]
    end

    # Choosing *Choose a type* is a choice. Falling back to the suggestion here would put a type
    # back that the person had deliberately taken off.
    test "is nothing when the replayed change carried nothing chosen" do
      assert selected(proposal_html(%{"propose-v1" => %{"ticket_type" => ""}})) == []
    end
  end

  describe "a human state's document" do
    setup %{user: user} do
      workflow =
        Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__)
        |> File.read!()
        |> String.replace(
          "  review_ready: {}",
          "  review_ready:\n    produces: [test-report.md]"
        )

      {:ok, project} =
        Projects.register(
          %{
            name: "rcd-#{System.unique_integer([:positive])}",
            repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
          },
          user
        )

      {:ok, ticket} = Tickets.admit(project, %{title: "Try it"}, {:user, user.id})

      {:ok, ticket} =
        ticket |> Ecto.Changeset.change(state: "review_ready") |> Forge.Repo.update()

      %{project: project, ticket: ticket}
    end

    test "is in a form a rejoin can replay, and comes back when it does", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      path = ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide"
      {:ok, view, html} = live(conn, path)
      assert html =~ "test-report.md"
      assert_recoverable(html, "a human state's document")

      view
      |> form(~s(form[id="write-test-report.md"]), %{"content" => "half of a sentence"})
      |> render_change()

      assert view |> element(~s([id="write-test-report.md"])) |> render() =~
               "half of a sentence"
    end

    # The draft outlives the socket, not the send. Left behind, it would be drawn over the
    # version that was just written — and over every later one.
    test "stops holding the draft once it is saved", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      path = ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide"
      {:ok, view, _html} = live(conn, path)

      view
      |> form(~s(form[id="write-test-report.md"]), %{"content" => "half of a sentence"})
      |> render_change()

      view
      |> form(~s(form[id="write-test-report.md"]), %{"content" => "the whole thing\n"})
      |> render_submit()

      assert %{version: 1, content: "the whole thing\n"} =
               Forge.Artifacts.latest(ticket.id, "test-report.md")

      editor = view |> element(~s([id="write-test-report.md"])) |> render()
      assert editor =~ "the whole thing"
      refute editor =~ "half of a sentence"
    end
  end
end
