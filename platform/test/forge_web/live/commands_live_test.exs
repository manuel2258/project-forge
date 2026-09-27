defmodule ForgeWeb.CommandsLiveTest do
  @moduledoc """
  Commands as the operator sees them (`docs/design/ui.md` § Decide and Timeline): a row on the
  ticket's timeline with its exit status and duration, indented beneath the job that invoked it,
  and a page of its own with the script, the argument vector, the commit and the log.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{FakeWorker, Jobs, Projects, Tickets}

  @workflow """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      produces: build.log
      timeout: 20m
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md, changeset]
      may_invoke:
        build: { max: 3 }
      budget: { turns: 20, cost: 2.00 }
    checking:
      invoke: [[build, --all, "a b"]]
      exit: { 0: done, "*": failed }
    review_ready: {}
  transitions:
    - { from: implementing, to: checking }
    - { from: checking, to: review_ready }
    - { from: checking, to: implementing, when: failed }
  limits:
    ticket_cost: 25.00
  """

  setup :register_and_log_in_user

  setup %{user: user} do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/commands/build.sh" => "#!/bin/sh\nexec make \"$@\"\n"
      })

    {:ok, project} =
      Projects.register(
        %{name: "cl-#{System.unique_integer([:positive])}", repo_path: repo},
        user
      )

    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Build it"}, {:user, user.id})
    %{project: project, ticket: ticket, worker: FakeWorker.connect()}
  end

  defp page(project, ticket, rest), do: "/tickets/#{project.name}/#{ticket.number}" <> rest

  defp commands(ticket), do: Jobs.commands_for_ticket(ticket.id)

  # An agent that invoked `build` twice, one command finished and one still pending.
  defp invoked(%{ticket: ticket, worker: worker}) do
    [job] = Jobs.for_ticket(ticket.id)
    assignment = FakeWorker.assign(job, worker)

    {:ok, _parked} =
      FakeWorker.park(assignment, [
        %{"command" => "build", "args" => ["--release"]},
        %{"command" => "build", "args" => []}
      ])

    [first, second] = ticket |> commands() |> Enum.sort_by(& &1.attempt)
    {:ok, _} = first |> FakeWorker.assign(worker) |> FakeWorker.finish_command(3, log: "boom\n")
    %{parent: job, finished: first, pending: second}
  end

  test "an agent's commands are rows beneath it, with their exit status", context do
    %{parent: parent, finished: finished, pending: pending} = invoked(context)

    {:ok, view, _html} =
      live(context.conn, page(context.project, context.ticket, "?tab=timeline"))

    row = view |> element("#command-#{finished.id}") |> render()
    assert row =~ "build"
    assert row =~ ~s([&quot;--release&quot;])
    assert row =~ "exit 3"
    assert row =~ "text-error"
    assert row =~ "pl-8"

    assert row =~
             ~p"/tickets/#{context.project.name}/#{context.ticket.number}/jobs/#{finished.id}"

    assert view |> element("#command-#{pending.id}") |> render() =~ "pending"
    assert Jobs.get!(parent.id).status == :parked
    assert render(view) =~ "parked"

    # Beneath it: after the agent's own row, in the order the work was made.
    html = render(view)
    parent_href = ~p"/tickets/#{context.project.name}/#{context.ticket.number}/jobs/#{parent.id}"
    {agent_at, _} = :binary.match(html, parent_href)
    {first_at, _} = :binary.match(html, ~s(id="command-#{finished.id}"))
    {second_at, _} = :binary.match(html, ~s(id="command-#{pending.id}"))
    assert agent_at < first_at and first_at < second_at
  end

  test "a command state's commands are its step's rows, not indented", context do
    [job] = Jobs.for_ticket(context.ticket.id)
    written = %{"implementation.md" => "---\noutcome: done\n---\n# Done\n"}
    {:ok, _} = FakeWorker.run(job, context.worker, "success", written: written)

    [build] = commands(context.ticket)
    {:ok, _} = build |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)

    {:ok, view, _html} =
      live(context.conn, page(context.project, context.ticket, "?tab=timeline"))

    row = view |> element("#command-#{build.id}") |> render()

    assert row =~ "exit 0"
    assert row =~ "text-success"
    refute row =~ "pl-8"
  end

  test "a command's page shows the script, its arguments as a vector, its commit and log",
       context do
    %{finished: finished, parent: parent} = invoked(context)

    {:ok, view, html} =
      live(context.conn, page(context.project, context.ticket, "/jobs/#{finished.id}"))

    assert view |> element("#command-script") |> render() =~ "exec make"
    assert view |> element("#command-args") |> render() =~ "[&quot;--release&quot;]"
    assert html =~ "exit 3"
    assert html =~ String.slice(Jobs.spec(finished).command["at"], 0, 12)
    assert has_element?(view, ~s(a[href$="/jobs/#{parent.id}"]), "invoked by implementing")
    assert has_element?(view, ~s(a[href$="/artifacts/build.log/1"]))

    # None of an agent's: no turns, no budget, no prompt.
    refute html =~ "State prompt"
    refute html =~ "Turns"
  end

  # Not "declares no artifact" for a command that does, and simply has not ended.
  test "a command still to run says its log comes when it ends", context do
    %{pending: pending} = invoked(context)

    {:ok, _view, html} =
      live(context.conn, page(context.project, context.ticket, "/jobs/#{pending.id}"))

    assert html =~ "recorded on the ticket once the command ends"
    refute html =~ "declares no artifact"
  end
end
