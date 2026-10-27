defmodule Forge.EffortTest do
  @moduledoc """
  How hard the work thinks.

  The second dial beside the model, and the chain is again the whole feature: a workflow state's,
  then the project's, then the machine's. Tested from the outside — `effort_for/1` is what the
  assignment asks — because the failure mode is the same silent one: a job that thinks at the
  wrong effort produces work, just not the work that was asked for.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.Accounts.User
  alias Forge.{Conversations, Jobs, Operator, Projects}
  alias Forge.Events.Event
  alias Forge.Git.Tokens
  alias Forge.Jobs.Job

  setup do
    {:ok, project} =
      register_owned!(%{
        name: "effort-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    %{project: project}
  end

  describe "a project's default" do
    test "is set and cleared, and empty means cleared", %{project: project} do
      assert {:ok, project} = Projects.set_effort(project, "high")
      assert project.effort == "high"

      # Not "the effort named empty string": cleared, which resolves to the machine's.
      assert {:ok, project} = Projects.set_effort(project, "   ")
      assert is_nil(project.effort)
    end

    # The stored value is what reaches `--effort` on a command line, so the padding a box or a
    # paste leaves is taken off here rather than failing the job on the machine. Ecto's own cast
    # already nils a value that is *only* whitespace; trimming one that is not is this code's.
    test "a padded level is stored without its padding", %{project: project} do
      assert {:ok, project} = Projects.set_effort(project, "  high  ")
      assert project.effort == "high"
    end

    # The levels belong to the harness, and this ticket exists so they can reach harnesses the
    # platform does not know. A validator holding Claude Code's five would refuse the sixth.
    test "any non-empty level is accepted, including one no harness has", %{project: project} do
      assert {:ok, project} = Projects.set_effort(project, "ponder-for-a-week")
      assert project.effort == "ponder-for-a-week"
    end

    # Each dial is set on its own: saving one must not clear the other, which a shared changeset
    # field or a shared setter would do.
    test "setting one dial leaves the other alone", %{project: project} do
      {:ok, project} = Projects.set_model(project, "opus")
      {:ok, project} = Projects.set_effort(project, "max")

      assert project.model == "opus"
      assert project.effort == "max"

      {:ok, project} = Projects.set_model(project, "haiku")
      assert project.effort == "max"
    end
  end

  describe "a conversation" do
    test "runs at the effort it was opened with", %{project: project} do
      {:ok, _project} = Projects.set_effort(project, "low")
      {:ok, chat} = Conversations.open(project, "hello", effort: "max")

      assert chat.effort == "max"
      assert Jobs.effort_for(chat) == "max"
    end

    test "falls back to the project's when it named none", %{project: project} do
      {:ok, project} = Projects.set_effort(project, "low")
      {:ok, chat} = Conversations.open(project, "hello")

      assert is_nil(chat.effort)
      assert Jobs.effort_for(chat) == "low"
    end

    # Nil at the end of the chain is not "no effort": it is the machine's, and a machine with no
    # `FORGE_CLAUDE_EFFORT` passes no flag at all, leaving the harness its own default.
    test "falls through to the machine's when nothing says", %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello")

      assert is_nil(Jobs.effort_for(chat))
    end

    test "an empty choice is the project's, not an effort named nothing", %{project: project} do
      {:ok, project} = Projects.set_effort(project, "medium")
      {:ok, chat} = Conversations.open(project, "hello", effort: "  ")

      assert is_nil(chat.effort)
      assert Jobs.effort_for(chat) == "medium"
    end

    # The padded case is the only one that proves `chosen/2`'s trim: Ecto's `cast` folds a
    # whitespace-only value to nil on its own, so `"   "` above would pass without this code.
    # What reaches `--effort` is one argv slot, so padding has to come off before the machine.
    test "a padded choice is stored without its padding", %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello", effort: "  high  ", model: "  opus  ")

      assert chat.effort == "high"
      assert chat.model == "opus"
    end

    # **A form parameter is not a string until something says so.** `chat[effort][x]=1` arrives
    # as a map and `chat[effort][]=hi&chat[effort][]=gh` as a list; `to_string/1` raised on the
    # first and silently returned `"high"` for the second, which is a conversation running at a
    # level nobody typed. Anything that is not a string is nobody's choice, so it resolves to the
    # project's — the same answer as naming nothing.
    test "a parameter that is not a string is refused rather than joined or crashed", %{
      project: project
    } do
      {:ok, project} = Projects.set_effort(project, "low")

      assert {:ok, chat} = Conversations.open(project, "hello", effort: ["hi", "gh"])
      assert is_nil(chat.effort)
      assert Jobs.effort_for(chat) == "low"

      assert {:ok, chat} = Conversations.open(project, "hello", effort: %{"x" => "1"})
      assert is_nil(chat.effort)

      assert {:ok, chat} = Conversations.open(project, "hello", model: ["hai", "ku"])
      assert is_nil(chat.model)
    end

    # The two are chosen together and are not the same choice: a conversation opened with one of
    # them must not acquire the other's value.
    test "its model and its effort are chosen independently", %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello", model: "opus")

      assert chat.model == "opus"
      assert is_nil(chat.effort)
    end
  end

  # Everything that already existed keeps working, and keeps thinking at the machine's effort.
  # Both columns are nullable and null is the bottom of the chain, so a row written before any of
  # this resolves exactly as it did.
  describe "what was already there" do
    test "a spec stored before the field existed has no effort, and no opinion", %{
      project: project
    } do
      ticket = ticket_fixture(%{project: project})

      # Exactly the shape on disk for every job created before this: no `effort` key at all.
      job = job_fixture(%{ticket: ticket, spec: %{"prompt" => "agents/refine.md"}})

      assert is_nil(Jobs.spec(job).effort)
      assert is_nil(Jobs.effort_for(job))
    end

    test "a project written before the column existed reads as no default", %{project: project} do
      assert is_nil(project.effort)
      assert is_nil(Jobs.effort_for(chat_fixture(%{project: project})))
    end

    # A workflow pinned before `effort` was a key still parses: it is stored as the raw map and
    # re-parsed, so a key nothing ever set is simply absent. Stripped from the map here, because
    # that is exactly what every workflow pinned before this change looks like.
    test "a workflow pinned before the key existed still parses", %{project: project} do
      ticket = ticket_fixture(%{project: project})

      without_effort =
        update_in(ticket.workflow, ["states"], fn states ->
          Map.new(states, fn {name, state} -> {name, Map.delete(state, "effort")} end)
        end)

      assert {:ok, workflow} = ForgeCore.Workflow.Parser.from_map(without_effort)
      assert Enum.all?(Map.values(workflow.states), &is_nil(&1.effort))
    end
  end

  describe "a workflow job" do
    test "runs at its state's effort, over the project's", %{project: project} do
      {:ok, _project} = Projects.set_effort(project, "low")
      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket, spec: %{"effort" => "max"}})

      assert Jobs.effort_for(job) == "max"
    end

    test "falls back to the project's when its state named none", %{project: project} do
      {:ok, _project} = Projects.set_effort(project, "low")
      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket, spec: %{}})

      assert Jobs.effort_for(job) == "low"
    end

    # The stored spec keeps what the *state* declared, which is pinned with the workflow. The
    # project's default is not pinned, so it is read when the job runs rather than when it was
    # created — a job made a week ago should use the project's answer now.
    test "the project's answer is read when the job runs, not when it was created", %{
      project: project
    } do
      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket, spec: %{}})

      assert is_nil(Jobs.effort_for(job))

      {:ok, _project} = Projects.set_effort(project, "xhigh")

      assert Jobs.effort_for(Repo.get!(Job, job.id)) == "xhigh"
    end

    # `effort_for/1` reads the project's column and not the model's. Two single-column queries
    # that differ by one field are exactly where a copy goes wrong silently.
    test "reads the project's effort, not its model", %{project: project} do
      {:ok, _project} = Projects.set_model(project, "opus")
      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket, spec: %{}})

      assert is_nil(Jobs.effort_for(job))
      assert Jobs.model_for(job) == "opus"
    end
  end

  # **Resolving it is not the same claim as handing it over.** Every test above calls
  # `effort_for/1`; none of them asked whether anything *uses* it, and deleting the line in
  # `runtime_spec/2` that puts it into the spec left all 2535 platform tests green. The
  # assignment is what a worker is handed, so this is where both dials have to be asserted.
  describe "the assignment a worker is handed" do
    # A budget, because `runtime_spec/2` lowers one just after it resolves the dials: a spec with
    # none raises on `spec.budget.cost` before any caller sees the assignment, so these tests
    # would never get to look at the field they are about.
    @spec_with_budget %{
      "prompt" => "agents/refine.md",
      "budget" => %{"turns" => 10, "cost" => 1.0}
    }

    setup %{project: project} do
      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket, spec: @spec_with_budget})
      {:ok, token, _row} = Tokens.issue_for_job(job, ticket, project)

      %{ticket: ticket, job: job, token: token}
    end

    test "carries the resolved effort, and the resolved model beside it", context do
      %{project: project, ticket: ticket, job: job, token: token} = context
      {:ok, _project} = Projects.set_effort(project, "xhigh")
      {:ok, _project} = Projects.set_model(project, "opus")

      spec = Jobs.assignment(job, ticket, project, token)["spec"]

      assert spec["effort"] == "xhigh"
      assert spec["model"] == "opus"
    end

    # A state's own wins over the project's here too. The resolution is the same function either
    # way; that the assignment calls *that* function is the part nothing checked.
    test "prefers the state's effort over the project's", context do
      %{project: project, ticket: ticket, token: token} = context
      {:ok, _project} = Projects.set_effort(project, "low")

      job =
        job_fixture(%{
          ticket: ticket,
          attempt: 2,
          spec: Map.put(@spec_with_budget, "effort", "max")
        })

      assert Jobs.assignment(job, ticket, project, token)["spec"]["effort"] == "max"
    end

    test "carries no effort when nothing in the chain names one", context do
      %{project: project, ticket: ticket, job: job, token: token} = context

      assert is_nil(Jobs.assignment(job, ticket, project, token)["spec"]["effort"])
    end
  end

  # Who turned a project's effort up is who turned its spend up, so the log has to name them.
  describe "the audit log" do
    test "names the person who set the effort, not the system", %{project: project} do
      admin = Forge.AccountsFixtures.user_fixture()
      join!(project, admin)

      assert {:ok, _project} = Operator.set_effort(project, admin, "high")

      assert [event] = events("project.effort_set")
      assert event.actor == %{"kind" => "user", "id" => admin.id}
      assert event.payload == %{"project" => project.name, "effort" => "high"}
    end

    # The platform setting one on its own still has an actor, and it is not a person.
    test "says system when no person did it", %{project: project} do
      assert {:ok, _project} = Projects.set_effort(project, "low")

      assert [event] = events("project.effort_set")
      assert event.actor == %{"kind" => "system", "id" => nil}
    end

    # **The log is part of the write.** `Events.append/3`'s result used to be discarded, so a
    # rejected event left the effort changed, nothing logged, and `{:ok, project}` returned —
    # the one outcome a function about attribution must not have. A `%User{}` with no id is the
    # reachable way to make the event's changeset fail: it passes the head's guard and
    # `encode_actor/1` turns it into an actor the `Event` changeset refuses.
    test "a rejected event rejects the change", %{project: project} do
      {:ok, project} = Projects.set_effort(project, "low")

      assert {:error, _reason} = Projects.set_effort(project, "max", %User{})

      assert Projects.get!(project.id).effort == "low"
      assert [_only_the_first] = events("project.effort_set")
    end

    # The same property from the other side, and the scenario the review named: a `by` that is
    # neither a user nor the system raises in `actor/1`, and because that happens while the
    # `Multi` is built the setting is untouched. Under the old non-transactional shape the update
    # had already committed by then, which this would catch.
    test "an actor that cannot be encoded leaves the setting alone", %{project: project} do
      {:ok, project} = Projects.set_effort(project, "low")

      assert_raise FunctionClauseError, fn -> Projects.set_effort(project, "max", :nobody) end

      assert Projects.get!(project.id).effort == "low"
    end
  end

  defp events(type), do: Repo.all(from e in Event, where: e.type == ^type, order_by: e.seq)
end
