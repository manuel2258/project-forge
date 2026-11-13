defmodule ForgeWeb.ToastTest do
  @moduledoc """
  A toast's second line names what a move started (`docs/design/ui.md` § Toasts), not the state
  it reached: *planning started*, *in the merge queue*, *merged into main*, and *moved to
  `<state>`* only where nothing starts (UX pass, A31).
  """

  use Forge.DataCase, async: true

  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{Projects, Repo, Tickets}
  alias ForgeWeb.Toast

  # Every kind of state the line tells apart: a job state, a command state, a state a person
  # decides in, and one whose entry merges.
  @workflow """
  version: 1
  initial: planning
  commands:
    build:
      run: .forge/commands/build.sh
      produces: build.log
      timeout: 20m
  states:
    planning:
      prompt: agents/plan.md
      produces: [plan.md]
    checking:
      invoke: [[build]]
      exit: { 0: done, "*": failed }
    review_ready: {}
    merged:
      on_enter: merge
  transitions:
    - { from: planning, to: checking }
    - { from: checking, to: review_ready }
    - { from: checking, to: planning, when: failed }
    - { from: review_ready, to: merged, approve: [changeset] }
  limits:
    ticket_tokens: 5M
  """

  setup do
    {:ok, project} =
      Projects.register(
        %{name: "toast-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user_fixture()
      )

    {:ok, ticket} = Tickets.admit(project, %{title: "Move it"}, :system)

    # The pin as it comes back from jsonb: decoded YAML with every key a string.
    pin = @workflow |> YamlElixir.read_from_string!() |> Jason.encode!() |> Jason.decode!()

    %{project: project, ticket: %{ticket | workflow: pin}}
  end

  defp at(ticket, state, status \\ :active), do: %{ticket | state: state, status: status}

  test "a job state and a command state say they started", %{ticket: ticket} do
    assert {:ok, _workflow} = Tickets.parsed_workflow(ticket)
    assert Toast.started(at(ticket, "planning")) == "planning started"
    assert Toast.started(at(ticket, "checking")) == "checking started"
  end

  test "a state a person decides in says where it moved", %{ticket: ticket} do
    assert Toast.started(at(ticket, "review_ready")) == "moved to review_ready"
  end

  test "a merge says where it merged, and only once it has", %{project: project, ticket: ticket} do
    assert Toast.started(at(ticket, "merged", :done)) == "merged into #{project.default_branch}"
    # In the merging state but not done — a merge that conflicted and was routed on — merged
    # nothing.
    assert Toast.started(at(ticket, "merged")) == "moved to merged"
    # Done in a state whose entry merges nothing merged nothing either.
    assert Toast.started(at(ticket, "review_ready", :done)) == "moved to review_ready"
  end

  test "a ticket in the merge queue says so before anything else", %{ticket: ticket} do
    Repo.insert!(%Forge.MergeQueue.Entry{
      project_id: ticket.project_id,
      ticket_id: ticket.id,
      from_state: "review_ready",
      to_state: "merged",
      edge_outcome: "done"
    })

    assert Toast.started(at(ticket, "planning")) == "in the merge queue"
  end

  test "a pin that no longer parses says where it moved", %{ticket: ticket} do
    broken = %{ticket | workflow: %{"no longer" => "a workflow"}, state: "planning"}
    assert Toast.started(broken) == "moved to planning"
  end
end
