defmodule ForgeWeb.ExtendLiveTest do
  @moduledoc """
  Extending a job that ran out of budget, and running a state again with a note, from the ticket
  page and the queue (`docs/design/ui.md` § Steps, *Ways forward*; `docs/design/workflow-grammar-v1.md`
  § Extending a job). The two surfaces draw the same fields from one component.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.ForgeFixtures, only: [funded!: 1]
  import Forge.GitFixtures

  alias Forge.{FakeWorker, Jobs, Projects, Repo, Tickets}
  alias Forge.Jobs.Extensions

  @workflow """
  version: 1
  initial: implementing
  states:
    implementing:
      prompt: agents/implement.md
      inputs: [ticket]
      produces: [implementation.md]
      budget: { turns: 150, tokens: 12M }
    review_ready: {}
  transitions:
    - { from: implementing, to: review_ready }
  limits:
    ticket_tokens: 100M
  """

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{
          name: "ext-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => @workflow})
        },
        user
      )

    funded!(project)
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    worker = FakeWorker.connect()
    job = run_out(ticket, worker)

    %{project: project, ticket: Tickets.get!(ticket.id), job: job, worker: worker}
  end

  defp run_out(ticket, worker) do
    [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.status == :pending))
    assignment = FakeWorker.assign(job, worker)

    {:ok, job} =
      FakeWorker.finish(assignment, "max_budget",
        written: %{},
        harness: %{
          "session_id" => "sess-42",
          "session_blob" => assignment["store"]["session_prefix"] <> "1.jsonl",
          "version" => "2.1.284",
          "usage" => 12_000_000
        }
      )

    job
  end

  defp page(conn, project, ticket), do: live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

  defp pick(view, way), do: view |> form("#ways-forward", %{"way" => way}) |> render_change()

  # Leaves `left` of the ticket's 100M.
  defp leaving(ticket, left),
    do: ticket |> Ecto.Changeset.change(usage: 100_000_000 - left) |> Repo.update!()

  describe "the ticket page" do
    test "Extend is a row above Run again, and opens its fields at half the state's budget",
         %{conn: conn, project: project, ticket: ticket} do
      {:ok, view, _html} = page(conn, project, ticket)

      assert has_element?(view, "#ways-forward #way-extend")
      assert has_element?(view, "#ways-forward #way-again")
      assert has_element?(view, "#ways-forward", "Extend implementing")
      html = render(view)
      assert :binary.match(html, "way-extend") < :binary.match(html, "way-again")

      # Nothing open until a way is picked.
      refute has_element?(view, "#forward-extend-fields")
      pick(view, "extend")

      assert has_element?(view, "#ways-forward #forward-extend-fields")
      assert has_element?(view, ~s(#forward-extend-tokens[value="6M"]))
      assert has_element?(view, ~s(#forward-extend-turns[value="75"]))
      assert has_element?(view, "#forward-extend-note")
      assert has_element?(view, "#forward-extend-facts", "ran out of tokens")
      assert has_element?(view, "#forward-extend-facts", "12M")
      assert has_element?(view, "#forward-extend-fields", "on top of")
      # Plenty left of the cap: no raise.
      refute has_element?(view, "#forward-extend-raise")
    end

    test "extending reopens the job with the figures and the note, and the ticket goes on",
         %{conn: conn, project: project, ticket: ticket, job: job} do
      {:ok, view, _html} = page(conn, project, ticket)
      pick(view, "extend")

      html =
        view
        |> form("#ways-forward", %{
          "way" => "extend",
          "tokens" => "3M",
          "turns" => "20",
          "note" => "Finish the review."
        })
        |> render_submit()

      assert html =~ "Extended implementing"
      assert %{status: :active} = Tickets.get!(ticket.id)
      assert %{status: :pending} = Jobs.get!(job.id)

      assert [%{tokens: 3_000_000, turns: 20, note: "Finish the review."}] =
               Extensions.all(job.id)

      # The pick is let go once it was done.
      refute has_element?(view, "#forward-extend-fields")
    end

    test "the raise box appears only past what is left, filled with the shortfall",
         %{conn: conn, project: project, ticket: ticket} do
      leaving(ticket, 4_000_000)
      {:ok, view, _html} = page(conn, project, ticket)
      pick(view, "extend")

      # 6M against 4M left: short by 2M.
      assert has_element?(view, "#forward-extend-raise")
      assert has_element?(view, ~s(#forward-extend-raise-box[value="2M"]))
      assert has_element?(view, "#forward-extend-raise-says", "100M")
      assert has_element?(view, "#forward-extend-raise-says", "102M")

      # It follows the tokens: the box is in the form when they change, and carries the old
      # shortfall with it, which must not stay. A browser says which field changed.
      view
      |> form("#ways-forward", %{"way" => "extend", "tokens" => "9M"})
      |> render_change(%{"_target" => ["tokens"]})

      assert has_element?(view, ~s(#forward-extend-raise-box[value="5M"]))
      assert has_element?(view, "#forward-extend-raise-says", "105M")

      # Type less, and it goes.
      view
      |> form("#ways-forward", %{"way" => "extend", "tokens" => "3M"})
      |> render_change(%{"_target" => ["tokens"]})

      refute has_element?(view, "#forward-extend-raise")

      # A figure that is not an amount draws no raise and is refused on submit.
      view |> form("#ways-forward", %{"way" => "extend", "tokens" => "lots"}) |> render_change()
      refute has_element?(view, "#forward-extend-raise")
    end

    test "the raise is taken with the act, and a short one is refused where it was typed",
         %{conn: conn, project: project, ticket: ticket, job: job} do
      leaving(ticket, 4_000_000)
      {:ok, view, _html} = page(conn, project, ticket)
      pick(view, "extend")

      view
      |> form("#ways-forward", %{"way" => "extend", "tokens" => "6M", "raise" => "1M"})
      |> render_change()

      html = view |> form("#ways-forward") |> render_submit()
      assert html =~ "raised by at least 2M"
      assert has_element?(view, "#forward-refusal[role=alert]")
      # Still open, with what was typed.
      assert has_element?(view, ~s(#forward-extend-tokens[value="6M"]))
      assert has_element?(view, ~s(#forward-extend-raise-box[value="1M"]))
      assert Extensions.all(job.id) == []

      view |> form("#ways-forward", %{"way" => "extend", "raise" => "2M"}) |> render_change()
      view |> form("#ways-forward") |> render_submit()

      assert %{cap_raise: 2_000_000, status: :active} = Tickets.get!(ticket.id)
      assert [_] = Extensions.all(job.id)
    end

    test "each refusal is drawn under the form with what was typed still in it",
         %{conn: conn, project: project, ticket: ticket} do
      {:ok, view, _html} = page(conn, project, ticket)
      pick(view, "extend")

      for {fields, words} <- [
            {%{"tokens" => "lots"}, "800k, 1.5M or 2000000"},
            {%{"tokens" => "1M", "turns" => "1.5"}, "positive whole number"},
            {%{"tokens" => "1M", "turns" => "5", "note" => String.duplicate("n", 4_001)}, "4000"}
          ] do
        view |> form("#ways-forward", Map.put(fields, "way", "extend")) |> render_change()
        html = view |> form("#ways-forward") |> render_submit()

        assert html =~ words
        assert has_element?(view, "#forward-refusal[role=alert]")
        assert has_element?(view, "#forward-extend-fields")
      end

      assert has_element?(view, ~s(#forward-extend-turns[value="5"]))
      assert Tickets.get!(ticket.id).status == :stuck
    end

    test "a job that went live again meanwhile is refused in words", ctx do
      %{conn: conn, project: project, ticket: ticket, job: job, user: user} = ctx
      {:ok, view, _html} = page(conn, project, ticket)
      pick(view, "extend")

      # Someone else extended it first.
      {:ok, _} = Forge.Operator.extend(ticket, user, job.id, %{"tokens" => "1M"})

      # The page has already moved on and no longer draws the form; a request sent from the page as
      # it was drawn is refused where the refusal is drawn without the ways.
      html =
        render_hook(view, "forward", %{
          "way" => "extend",
          "tokens" => "1M",
          "job" => job.id,
          "draft" => "ways-forward"
        })

      assert html =~ "not stuck"
      assert has_element?(view, "#forward-refusal")
      assert length(Extensions.all(job.id)) == 1
    end

    test "a note is shown as typed, never as markup, and wraps", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      {:ok, view, _html} = page(conn, project, ticket)
      pick(view, "extend")

      view
      |> form("#ways-forward", %{"way" => "extend", "note" => "<b>bold</b> & <script>x</script>"})
      |> render_change()

      html = render(view)
      assert html =~ "&lt;b&gt;bold&lt;/b&gt; &amp; &lt;script&gt;x&lt;/script&gt;"
      refute html =~ "<b>bold</b>"
      assert has_element?(view, "#forward-extend-note.\\[overflow-wrap\\:anywhere\\]")
    end

    test "a Codex job has no turns box", ctx do
      %{conn: conn, project: project, ticket: ticket, job: job} = ctx
      job |> Ecto.Changeset.change(harness: "codex") |> Repo.update!()
      {:ok, view, _html} = page(conn, project, ticket)
      pick(view, "extend")

      assert has_element?(view, "#forward-extend-tokens")
      refute has_element?(view, "#forward-extend-turns")

      view |> form("#ways-forward", %{"way" => "extend", "tokens" => "1M"}) |> render_submit()
      assert [%{tokens: 1_000_000, turns: nil}] = Extensions.all(job.id)
    end

    test "Run again takes a note and, with nothing left, a raise", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      leaving(ticket, 0)
      {:ok, view, _html} = page(conn, project, ticket)
      pick(view, "again")

      assert has_element?(view, "#forward-again-note")
      assert has_element?(view, ~s(#forward-again-raise-box[value="12M"]))
      refute has_element?(view, "#forward-again-tokens")

      view
      |> form("#ways-forward", %{"way" => "again", "note" => "Start smaller."})
      |> render_submit()

      assert %{status: :active, cap_raise: 12_000_000} = Tickets.get!(ticket.id)

      assert [%{attempt: 2} = next] =
               Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))

      assert Jobs.spec(next).entered["comment"] == "Start smaller."
    end

    test "Run again with something left says the run is lowered if the raise is emptied", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      leaving(ticket, 5_000_000)
      {:ok, view, _html} = page(conn, project, ticket)
      pick(view, "again")

      assert has_element?(view, ~s(#forward-again-raise-box[value="7M"]))
      refute has_element?(view, "#forward-again-raise-says", "lowered")

      # A raise typed over the shortfall is what the new cap is drawn from.
      view |> form("#ways-forward", %{"way" => "again", "raise" => "9M"}) |> render_change()
      assert has_element?(view, "#forward-again-raise-says", "109M")
      refute has_element?(view, "#forward-again-raise-says", "lowered")

      view |> form("#ways-forward", %{"way" => "again", "raise" => ""}) |> render_change()

      assert has_element?(
               view,
               "#forward-again-raise-says",
               "lowered to what the ticket has left"
             )

      # A raise of nothing is no raise, which the act treats the same way: still lowered.
      view |> form("#ways-forward", %{"way" => "again", "raise" => "0"}) |> render_change()

      assert has_element?(
               view,
               "#forward-again-raise-says",
               "lowered to what the ticket has left"
             )

      view |> form("#ways-forward") |> render_submit()
      assert %{status: :active, cap_raise: 0} = Tickets.get!(ticket.id)
    end

    test "Run again with nothing left is never said to be lowered", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      leaving(ticket, 0)
      {:ok, view, _html} = page(conn, project, ticket)
      pick(view, "again")

      view |> form("#ways-forward", %{"way" => "again", "raise" => ""}) |> render_change()
      refute has_element?(view, "#forward-again-raise-says", "lowered")

      # Nothing is left to run on, so an empty raise is refused rather than lowered.
      view |> form("#ways-forward") |> render_submit()
      assert has_element?(view, "#forward-refusal[role=alert]")
      assert %{status: :stuck} = Tickets.get!(ticket.id)
    end

    test "the note box is bounded at the note limit", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      {:ok, view, _html} = page(conn, project, ticket)
      pick(view, "extend")

      assert has_element?(view, ~s(#forward-extend-note[maxlength="4000"]))
    end

    test "a ticket whose job left no session offers Run again alone", ctx do
      %{conn: conn, project: project, ticket: ticket, job: job} = ctx
      job |> Ecto.Changeset.change(session_blob: nil) |> Repo.update!()
      {:ok, view, _html} = page(conn, project, ticket)

      refute has_element?(view, "#way-extend")
      assert has_element?(view, "#way-again")
    end

    test "the allowance says it was raised, and from what", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      ticket |> Ecto.Changeset.change(cap_raise: 20_000_000) |> Repo.update!()
      {:ok, view, _html} = page(conn, project, ticket)

      assert has_element?(view, "#ticket-usage", "raised from")
    end
  end

  describe "the queue's stuck item" do
    defp queue_pick(view, ticket, way),
      do: view |> form("#ways-#{ticket.id}", %{"way" => way}) |> render_change()

    test "offers the same two rows and the same fields", ctx do
      %{conn: conn, ticket: ticket} = ctx
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "label[for='way-#{ticket.id}-extend']", "Extend implementing")
      assert has_element?(view, "label[for='way-#{ticket.id}-retry']", "Retry implementing")
      refute has_element?(view, "#queue-#{ticket.id}-extend-fields")

      queue_pick(view, ticket, "extend")
      assert has_element?(view, ~s(#queue-#{ticket.id}-extend-tokens[value="6M"]))
      assert has_element?(view, ~s(#queue-#{ticket.id}-extend-turns[value="75"]))
      assert has_element?(view, "#queue-#{ticket.id}-extend-note")

      queue_pick(view, ticket, "retry")
      refute has_element?(view, "#queue-#{ticket.id}-extend-fields")
      assert has_element?(view, "#queue-#{ticket.id}-again-note")
    end

    test "extends the job, and the item leaves the queue", ctx do
      %{conn: conn, ticket: ticket, job: job} = ctx
      {:ok, view, _html} = live(conn, ~p"/")
      queue_pick(view, ticket, "extend")

      view
      |> form("#ways-#{ticket.id}", %{"way" => "extend", "tokens" => "2M", "note" => "Careful."})
      |> render_submit()

      assert %{status: :active} = Tickets.get!(ticket.id)
      assert [%{tokens: 2_000_000, note: "Careful."}] = Extensions.all(job.id)
      refute has_element?(view, "#ways-#{ticket.id}")
    end

    test "draws the raise box past what is left, and refuses a short one in place", ctx do
      %{conn: conn, ticket: ticket, job: job} = ctx
      leaving(ticket, 1_000_000)
      {:ok, view, _html} = live(conn, ~p"/")
      queue_pick(view, ticket, "extend")

      assert has_element?(view, ~s(#queue-#{ticket.id}-extend-raise-box[value="5M"]))

      view
      |> form("#ways-#{ticket.id}", %{"way" => "extend", "raise" => "1M"})
      |> render_change()

      view |> form("#ways-#{ticket.id}") |> render_submit()
      assert has_element?(view, "#queue-refusal[role=alert]", "raised by at least 5M")
      assert has_element?(view, ~s(#queue-#{ticket.id}-extend-raise-box[value="1M"]))
      assert Extensions.all(job.id) == []
    end

    test "runs again with a note", ctx do
      %{conn: conn, ticket: ticket} = ctx
      {:ok, view, _html} = live(conn, ~p"/")
      queue_pick(view, ticket, "retry")

      view
      |> form("#ways-#{ticket.id}", %{"way" => "retry", "note" => "From the top."})
      |> render_submit()

      assert [%{attempt: 2} = next] =
               Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))

      assert Jobs.spec(next).entered["comment"] == "From the top."
    end
  end

  describe "the queue's stuck item, beyond the happy path" do
    test "a raise typed under Run again is taken with it", ctx do
      %{conn: conn, ticket: ticket} = ctx
      leaving(ticket, 1_000_000)
      {:ok, view, _html} = live(conn, ~p"/")
      queue_pick(view, ticket, "retry")

      # 12M asked of a ticket with 1M left: the box is drawn, filled, and what is typed is taken.
      assert has_element?(view, ~s(#queue-#{ticket.id}-again-raise-box[value="11M"]))

      view
      |> form("#ways-#{ticket.id}", %{"way" => "retry", "raise" => "11M"})
      |> render_submit()

      assert %{cap_raise: 11_000_000, status: :active} = Tickets.get!(ticket.id)
    end

    test "changing the tokens drops an earlier shortfall and fills the new one", ctx do
      %{conn: conn, ticket: ticket} = ctx
      leaving(ticket, 1_000_000)
      {:ok, view, _html} = live(conn, ~p"/")
      queue_pick(view, ticket, "extend")
      assert has_element?(view, ~s(#queue-#{ticket.id}-extend-raise-box[value="5M"]))

      view
      |> form("#ways-#{ticket.id}", %{"way" => "extend", "tokens" => "3M", "raise" => "5M"})
      |> render_change(%{"_target" => ["tokens"]})

      assert has_element?(view, ~s(#queue-#{ticket.id}-extend-raise-box[value="2M"]))
    end

    test "a stuck ticket whose job left no session is offered Run again alone", ctx do
      %{conn: conn, ticket: ticket, job: job} = ctx
      job |> Ecto.Changeset.change(session_blob: nil) |> Repo.update!()
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Retry implementing"
      refute html =~ "Extend implementing"
    end
  end

  describe "the job page and the activity" do
    test "a job nobody extended says nothing of it, though its first run did not resume", ctx do
      %{conn: conn, project: project, ticket: ticket, job: job} = ctx

      # The worker reports `resumed: false` for every run that had no session to resume, a job's
      # first included: only a run an extension reopened is said to have started without it.
      Repo.update_all(from(r in Forge.Jobs.Run, where: r.job_id == ^job.id),
        set: [resumed: false]
      )

      {:ok, view, _html} =
        live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

      refute has_element?(view, "#job-extensions")
      refute render(view) =~ "started without its session"
    end

    test "lists the extensions oldest first, with who, the raise and the note as text", ctx do
      %{conn: conn, project: project, ticket: ticket, job: job, user: user, worker: worker} = ctx
      leaving(ticket, 4_000_000)

      {:ok, _} =
        Forge.Operator.extend(Tickets.get!(ticket.id), user, job.id, %{
          "tokens" => "6M",
          "turns" => "75",
          "raise" => "2M",
          "note" => "<b>first</b>\nline two"
        })

      {_, job} = {nil, again(ticket, worker)}
      {:ok, _} = Forge.Operator.extend(Tickets.get!(ticket.id), user, job.id, %{"tokens" => "1M"})

      {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

      assert has_element?(view, "#job-extensions", "Extensions")
      [first, second] = Extensions.all(job.id)
      assert has_element?(view, "#extension-#{first.id}", "extension 1")
      assert has_element?(view, "#extension-#{first.id}", "+6M, +75 turns")
      assert has_element?(view, "#extension-#{first.id}", user.email)
      assert has_element?(view, "#extension-#{first.id}", "cap raised 100M → 102M")
      assert has_element?(view, "#extension-#{second.id}", "extension 2")

      assert :binary.match(html, "extension-#{first.id}") <
               :binary.match(html, "extension-#{second.id}")

      # Markup is shown as typed, and the line break is kept.
      assert has_element?(view, "#extension-#{first.id}-note.whitespace-pre-wrap")
      # The extension's own note, not the stream's line for the same event, which escapes it too.
      note = view |> element("#extension-#{first.id}-note") |> render()
      assert note =~ "&lt;b&gt;first&lt;/b&gt;\nline two"
      refute note =~ "<b>first</b>"

      # Each run says which extension started it; the second extension has not been run yet.
      runs = Jobs.Runs.for_job(job.id)
      first_run = Enum.find(runs, &is_nil(&1.extension_id))
      run2 = Enum.find(runs, & &1.extension_id)
      refute has_element?(view, "#run-#{first_run.id}-extension")
      assert has_element?(view, "#run-#{run2.id}-extension", "extension 1")
    end

    # Only a run an extension reopened is said to have started without its session, and only when it
    # did not resume: one that did is labelled with its extension and nothing more.
    test "says a run an extension reopened started without its session, and only that", ctx do
      %{conn: conn, project: project, ticket: ticket, job: job, user: user, worker: worker} = ctx
      {:ok, _} = Forge.Operator.extend(ticket, user, job.id, %{"tokens" => "1M"})
      again(ticket, worker, %{"resumed" => false})

      {:ok, _} = Forge.Operator.extend(Tickets.get!(ticket.id), user, job.id, %{"tokens" => "1M"})
      again(ticket, worker, %{"resumed" => true})

      {:ok, view, _html} =
        live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

      # Runs are timed to the second, so they are found by the extension that started them.
      [one, two] = Extensions.all(job.id)
      runs = Jobs.Runs.for_job(job.id)
      cold = Enum.find(runs, &(&1.extension_id == one.id))
      resumed = Enum.find(runs, &(&1.extension_id == two.id))
      first = Enum.find(runs, &is_nil(&1.extension_id))
      refute has_element?(view, "#run-#{first.id}-cold")
      assert has_element?(view, "#run-#{cold.id}-cold", "started without its session")
      assert has_element?(view, "#run-#{resumed.id}-extension", "extension 2")
      refute has_element?(view, "#run-#{resumed.id}-cold")
    end

    test "a requeued run lets go of its extension, and the cold run that follows takes it", ctx do
      %{conn: conn, project: project, ticket: ticket, job: job, user: user, worker: worker} = ctx
      {:ok, _} = Forge.Operator.extend(ticket, user, job.id, %{"tokens" => "1M"})
      assignment = Tickets.get!(ticket.id) |> pending_of() |> FakeWorker.assign(worker)
      {:ok, _} = FakeWorker.finish(assignment, "no_start")
      again(ticket, worker, %{"resumed" => false})

      {:ok, view, _html} =
        live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

      runs = Jobs.Runs.for_job(job.id)
      assert [%{id: id}] = Enum.filter(runs, & &1.extension_id)
      assert has_element?(view, "#run-#{id}-extension", "extension 1")
      assert has_element?(view, "#run-#{id}-cold", "started without its session")
    end

    # Criterion 33: a restart's note is the new attempt's arrival comment, drawn where the manifest
    # is, as the person typed it.
    test "a restart's note is drawn on the new attempt's page as its arrival, as text", ctx do
      %{conn: conn, project: project, ticket: ticket, job: first, user: user} = ctx

      # The first state's job arrived from nothing: no heading for it.
      {:ok, view, _html} =
        live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{first.id}")

      view |> element(~s(#job-panes button[value="manifest"])) |> render_click()
      refute has_element?(view, "#job-arrival")

      {:ok, _} = Forge.Operator.retry(ticket, user, note: "<b>Start</b> smaller.\nSecond line.")
      next = pending_of(ticket)
      assert next.attempt == 2

      {:ok, view, _html} =
        live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{next.id}")

      view |> element(~s(#job-panes button[value="manifest"])) |> render_click()
      assert has_element?(view, "#job-arrival", "How it arrived")
      assert has_element?(view, "#job-arrival", "from implementing")
      assert has_element?(view, "#job-arrival", "a person took it")

      comment = view |> element("#job-arrival-comment") |> render()
      assert comment =~ "&lt;b&gt;Start&lt;/b&gt; smaller.\nSecond line."
      refute comment =~ "<b>"
      assert comment =~ "whitespace-pre-wrap"
    end

    # An arrival by an edge with nothing written on it says where from and who, and draws no empty
    # comment under it.
    test "an arrival with no comment draws no comment", ctx do
      %{conn: conn, project: project, ticket: ticket, job: job} = ctx

      for comment <- [nil, ""] do
        entered = %{
          "from" => "refining",
          "outcome" => "done",
          "by" => "engine",
          "comment" => comment
        }

        job
        |> Ecto.Changeset.change(spec: Map.put(job.spec, "entered", entered))
        |> Repo.update!()

        {:ok, view, _html} =
          live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

        view |> element(~s(#job-panes button[value="manifest"])) |> render_click()
        assert has_element?(view, "#job-arrival", "from refining on done · the engine took it")
        refute has_element?(view, "#job-arrival-comment")
      end
    end

    test "On the ticket says a state run again, with its note, and who", ctx do
      %{conn: conn, project: project, ticket: ticket, user: user} = ctx
      {:ok, _} = Forge.Operator.retry(ticket, user, note: "Start smaller.")

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=activity")

      assert has_element?(view, "#ticket-events", "ticket.retried")
      assert has_element?(view, "#ticket-events", "ran implementing again · Start smaller.")
      assert has_element?(view, "#ticket-events", user.email)
    end

    test "On the ticket names each decision and who made it", ctx do
      %{conn: conn, project: project, ticket: ticket, job: job, user: user} = ctx
      leaving(ticket, 4_000_000)

      {:ok, _} =
        Forge.Operator.extend(Tickets.get!(ticket.id), user, job.id, %{
          "tokens" => "6M",
          "raise" => "2M",
          "note" => "Mind the tests."
        })

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=activity")

      assert has_element?(view, "#ticket-events", "job.extended")
      assert has_element?(view, "#ticket-events", "+6M")
      assert has_element?(view, "#ticket-events", "Mind the tests.")
      assert has_element?(view, "#ticket-events", "ticket.cap_raised")
      assert has_element?(view, "#ticket-events", "cap 100M → 102M")
      assert has_element?(view, "#ticket-events", user.email)
    end
  end

  defp pending_of(ticket),
    do: ticket.id |> Jobs.for_ticket() |> Enum.find(&(&1.status == :pending))

  # The reopened job's run, out of budget again.
  defp again(ticket, worker, harness \\ %{}) do
    assignment = Tickets.get!(ticket.id) |> pending_of() |> FakeWorker.assign(worker)

    {:ok, job} =
      FakeWorker.finish(assignment, "max_budget",
        written: %{},
        harness:
          Map.merge(
            %{
              "session_id" => "sess-42",
              "session_blob" => assignment["store"]["session_prefix"] <> "2.jsonl",
              "version" => "2.1.284"
            },
            harness
          )
      )

    job
  end
end
