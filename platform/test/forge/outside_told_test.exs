defmodule Forge.OutsideToldTest do
  @moduledoc """
  What later jobs are told about work done outside forge
  (`docs/design/outside-work.md` § What later jobs are told, criterion 11): every job placed after
  a hand-back carries the take-over — who, when, the step, the commits, the note — in its spec's
  `outside`, filled at assignment, and its manifest says so; one still open is not told, and a
  ticket nobody took over has nothing.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Engine, FakeWorker, Jobs, Operator, Tickets}
  alias Forge.Git.Tokens
  alias ForgeCore.Job.Spec

  setup do
    repo = seeded_repo()

    {:ok, project} =
      register_owned!(%{name: "told-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    {:ok, ticket} = Operator.admit(project, user, %{title: "An idea", on_hold: false})
    %{project: project, user: user, ticket: ticket, worker: FakeWorker.connect()}
  end

  defp fresh(ticket), do: Tickets.get!(ticket.id)
  defp pending(ticket), do: Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))

  defp outside_of(assignment), do: Spec.from_map(assignment["spec"]).outside

  test "a job placed after a hand-back is told who, when, where to, the commits and the note",
       ctx do
    %{ticket: ticket, user: user, project: project, worker: worker} = ctx
    {:ok, taken} = Operator.take_over(ticket, user, via: :page)
    sha = commit_file_on_branch(project, ticket.branch, "mine.txt", "from my pc")
    {:ok, _back} = Operator.hand_back(taken, user, note: "Fixed it `by hand`.", via: :api)

    [job] = pending(ticket)
    assignment = FakeWorker.assign(job, worker)

    assert [entry] = outside_of(assignment)
    user_id = user.id
    assert %{"kind" => "user", "id" => ^user_id, "name" => name} = entry["by"]
    assert name == user.email
    assert entry["back_by"]["id"] == user.id
    assert entry["via"] == "page" and entry["back_via"] == "api"
    assert entry["state"] == "refining" and entry["to"] == "refining"
    assert entry["note"] == "Fixed it `by hand`."
    assert [%{"sha" => ^sha, "subject" => _}] = entry["commits"]
    assert entry["more"] == 0
    assert {:ok, _at, _} = DateTime.from_iso8601(entry["at"])
    assert {:ok, _at, _} = DateTime.from_iso8601(entry["back_at"])

    manifest = ForgeCore.Prompt.manifest(Spec.from_map(assignment["spec"]), "/j")
    assert manifest =~ "## Worked on outside forge"
    assert manifest =~ "Fixed it `by hand`."
  end

  test "every later job is told, not only the next", ctx do
    %{ticket: ticket, user: user, worker: worker} = ctx
    {:ok, taken} = Operator.take_over(ticket, user)
    {:ok, _back} = Operator.hand_back(taken, user, note: "by hand")

    [first] = pending(ticket)
    {:ok, _} = FakeWorker.run(first, worker, "success", doc: "refinement.md")
    {:ok, planning} = Engine.decide(fresh(ticket), user.id, :approved, "ok")
    assert planning.state == "planning"

    [second] = pending(ticket)
    assignment = FakeWorker.assign(second, worker)
    assert [%{"note" => "by hand"}] = outside_of(assignment)
  end

  test "the token that handed it back is named by its name", ctx do
    %{ticket: ticket, project: project, worker: worker} = ctx
    {:ok, _secret, writer} = Tokens.issue(project, name: "my-pc", git: :developer, api: :write)
    {:ok, taken} = Operator.take_over(ticket, writer, via: :mcp)
    {:ok, _back} = Operator.hand_back(taken, writer, via: :mcp)

    [job] = pending(ticket)
    assert [entry] = outside_of(FakeWorker.assign(job, worker))
    assert %{"kind" => "api", "name" => "my-pc"} = entry["by"]
    assert %{"kind" => "api", "name" => "my-pc"} = entry["back_by"]
    assert entry["note"] == nil
  end

  test "a take-over still open is not told", ctx do
    %{ticket: ticket, user: user} = ctx
    {:ok, _taken} = Operator.take_over(ticket, user)
    assert Jobs.outside_of(ticket.id) == []
  end

  test "a ticket nobody took over has nothing, and its manifest has no section", ctx do
    %{ticket: ticket, worker: worker} = ctx
    [job] = pending(ticket)
    assert Jobs.outside_of(ticket.id) == []

    assignment = FakeWorker.assign(job, worker)
    assert outside_of(assignment) == []

    refute ForgeCore.Prompt.manifest(Spec.from_map(assignment["spec"]), "/j") =~
             "Worked on outside"
  end

  test "two take-overs are both told, the earlier first", ctx do
    %{ticket: ticket, user: user, worker: worker} = ctx
    {:ok, taken} = Operator.take_over(ticket, user)
    {:ok, back} = Operator.hand_back(taken, user, note: "first")
    {:ok, taken} = Operator.take_over(back, user)
    {:ok, _back} = Operator.hand_back(taken, user, note: "second")

    [job] = pending(ticket)

    assert [%{"note" => "first"}, %{"note" => "second"}] =
             outside_of(FakeWorker.assign(job, worker))
  end
end
