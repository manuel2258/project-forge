defmodule ForgeWeb.TicketStepsOrderLiveTest do
  @moduledoc """
  The order Steps draws a ticket's visits in once it has passed an update step
  (`docs/design/ui.md` § Steps): the order they happened, oldest first. Every job is placed by the
  creation event its own kind writes, and not only a workflow agent's `job.created` — a step
  conversation's `chat.opened`, a command an agent invoked (`command.invoked`) and a command
  state's (`commands.started`) — or a command made before an update visit is drawn after it, as a
  step of its own.

  The jobs here are made by the platform's own paths: a fixture's job writes no creation event,
  and would sort last whatever the code does.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Artifacts, Conversations, FakeWorker, Jobs, Operator, Projects, Repo, Tickets}
  alias Forge.Jobs.Job

  setup :register_and_log_in_user

  defp project!(user, workflow, files) do
    repo =
      seeded_repo(
        Map.merge(
          %{
            ".forge/workflow.yml" => workflow,
            ".forge/commands/build.sh" => "#!/bin/sh\nexec make \"$@\"\n"
          },
          files
        )
      )

    {:ok, project} =
      Projects.register(
        %{name: "ord-#{System.unique_integer([:positive])}", repo_path: repo},
        user
      )

    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)
    project
  end

  defp page(project, ticket), do: "/tickets/#{project.name}/#{ticket.number}?tab=steps"

  defp pending(ticket), do: ticket.id |> Jobs.for_ticket() |> Enum.find(&(&1.status == :pending))

  defp state_of(view, selector) do
    view
    |> element(selector <> " .ui-state")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
  end

  @commands_workflow """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      timeout: 20m
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md, changeset]
      may_invoke:
        build: { max: 3 }
      budget: { turns: 20, tokens: 400k }
    refresh:
      on_enter: update
    checking:
      invoke: [build]
      exit: { 0: done, "*": failed }
    review_ready: {}
  transitions:
    - { from: implementing, to: refresh }
    - { from: refresh, to: checking }
    - { from: checking, to: review_ready }
    - { from: checking, to: implementing, when: failed }
  limits:
    ticket_tokens: 5M
  """

  test "an agent's command stays in its agent's step, and a command state's in its own", %{
    conn: conn,
    user: user
  } do
    project = project!(user, @commands_workflow, %{})
    worker = FakeWorker.connect()
    {:ok, ticket} = Tickets.admit(project, %{title: "Build it"}, {:user, user.id})

    # The agent invokes `build` from `implementing`, it ends, and the ticket passes `refresh`.
    assignment = FakeWorker.assign(pending(ticket), worker)
    {:ok, _parked} = FakeWorker.park(assignment, [%{"command" => "build", "args" => []}])
    [invoked] = Jobs.commands_for_ticket(ticket.id)
    {:ok, _} = invoked |> FakeWorker.assign(worker) |> FakeWorker.finish_command(0)

    written = %{"implementation.md" => "---\noutcome: done\n---\n# Done\n"}
    {:ok, _} = FakeWorker.run(pending(ticket), worker, "success", written: written)

    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "checking"
    [agent] = Jobs.for_ticket(ticket.id)

    checked = Enum.find(Jobs.commands_for_ticket(ticket.id), &(&1.id != invoked.id))

    {:ok, view, _html} = live(conn, page(project, ticket))

    assert state_of(view, "#step-0") =~ "implementing"
    assert has_element?(view, "#step-0 a[href$='/jobs/#{agent.id}']")
    assert has_element?(view, "#step-0 #command-#{invoked.id}")
    assert has_element?(view, "#step-1 #update-visit-refresh")
    assert state_of(view, "#step-2") =~ "checking"
    assert has_element?(view, "#step-2 #command-#{checked.id}")
    refute has_element?(view, "#step-3")

    # `build` in `checking` fails and the work goes back to an agent made after it. The command
    # state's commands are placed by their `commands.started` and by nothing else: with no seq they
    # sort last, after the new agent, and the new agent becomes a step of its own.
    {:ok, _} = checked |> FakeWorker.assign(worker) |> FakeWorker.finish_command(1)
    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "implementing"

    {:ok, view, _html} = live(conn, page(project, ticket))

    assert state_of(view, "#step-0") =~ "implementing"
    assert has_element?(view, "#step-1 #update-visit-refresh")
    assert state_of(view, "#step-2") =~ "checking"
    assert has_element?(view, "#step-2 #command-#{checked.id}")
    assert state_of(view, "#step-3") =~ "implementing"
    refute has_element?(view, "#step-4")
  end

  @chat_workflow """
  version: 1
  initial: refining
  states:
    refining:
      chat: true
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
    refresh:
      on_enter: update
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md]
      budget: { turns: 5, tokens: 200k }
    review_ready: {}
  transitions:
    - { from: refining, to: refresh }
    - { from: refresh, to: implementing }
    - { from: implementing, to: review_ready }
  limits: { ticket_tokens: 5M }
  """

  test "a step conversation is the first step, ahead of the update visit after it", %{
    conn: conn,
    user: user
  } do
    project = project!(user, @chat_workflow, %{})
    {:ok, ticket} = Tickets.admit(project, %{title: "Refine it"}, {:user, user.id})
    [chat] = Jobs.step_chats_for_ticket(ticket.id)

    run!(chat)

    {:ok, chat} =
      Conversations.record_turn(chat, %{
        "turn" => 1,
        "commit" => String.duplicate("a", 40),
        "documents" => %{"refinement.md" => "# Refinement\n\nOne.\n"},
        "harness" => %{"turns" => 1, "usage" => 2_000, "cost_usd" => 0.01, "session_id" => "s"}
      })

    seen = %{"refinement.md" => Artifacts.latest(ticket.id, "refinement.md").version}
    {:ok, _} = Operator.accept_step(Repo.get!(Job, chat.id), user, "done", seen)

    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "implementing"

    {:ok, view, _html} = live(conn, page(project, ticket))

    assert has_element?(view, "#step-0 #step-chat-#{chat.id}")
    assert state_of(view, "#step-0") =~ "refining"
    assert has_element?(view, "#step-1 #update-visit-refresh")
    assert state_of(view, "#step-2") =~ "implementing"
    refute has_element?(view, "#step-3")
  end
end
