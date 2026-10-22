defmodule Forge.BlobsTest do
  @moduledoc """
  Groups of files on the platform (`docs/design/workflow-grammar-v1.md` § Semantics,
  `docs/design/storage.md` § Serving): where a job may put them, and which of what it reports are
  recorded — an agent's screenshots, and a packaging command's build for a person to download.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Events, FakeWorker, Jobs, Storage, Tickets}
  alias Forge.Storage.Token
  alias ForgeCore.Job.Result

  @workflow """
  version: 1
  initial: implementing
  commands:
    package:
      run: .forge/commands/package.sh
      produces: [package.log, pkg/*]
      timeout: 10m
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md, changeset, commit-message, shots/*]
      budget: { turns: 20, cost: 2.00 }
    packaging:
      invoke: [package]
      exit: { 0: done, "*": build_failed }
    human_testing:
      produces: [test-report.md]
    merged:
      on_enter: merge
  transitions:
    - { from: implementing, to: packaging }
    - { from: packaging, to: human_testing }
    - { from: packaging, to: implementing, when: build_failed, max: 2 }
    - { from: human_testing, to: merged, approve: [changeset] }
    - { from: human_testing, to: implementing }
  limits:
    ticket_cost: 25.00
  """

  setup do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/commands/package.sh" => "#!/bin/sh\nmkdir -p \"$FORGE_OUT/pkg\"\n"
      })

    {:ok, project} =
      register_owned!(%{name: "blob-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Ship it", body: "."}, {:user, user.id})
    %{ticket: ticket, worker: FakeWorker.connect()}
  end

  # What the worker does: each staged file to `<prefix><n>` with the prefix token, and the result
  # naming the keys.
  defp upload(assignment, files) do
    %{"prefix" => prefix, "token" => token} = assignment["outputs"]

    files
    |> Enum.with_index(1)
    |> Map.new(fn {{name, bytes}, n} ->
      key = prefix <> Integer.to_string(n)
      assert :ok = Token.verify(token, :put, key)
      {:ok, info} = Storage.put(key, bytes)
      {name, %{"key" => key, "size" => info.size}}
    end)
  end

  defp finish_agent(assignment, blobs, invalid \\ %{}) do
    FakeWorker.put_transcript(assignment)

    written = %{
      "implementation.md" => "---\noutcome: done\n---\n# Done\n",
      # This workflow merges, so a state has to produce `commit-message`; a job of this state
      # that wrote none would be `error` rather than `done`.
      "commit-message" => "Land the change\n"
    }

    result = FakeWorker.result(assignment, "success", written: written)
    Jobs.complete(assignment["job_id"], %{result | blobs: blobs, invalid_blobs: invalid})
  end

  describe "an agent's group" do
    test "is given a prefix of its own and recorded file by file", context do
      [job] = Jobs.for_ticket(context.ticket.id)
      assignment = FakeWorker.assign(job, context.worker)

      assert %{"prefix" => "job/" <> rest} = assignment["outputs"]
      assert String.starts_with?(rest, job.id <> "/out-")

      blobs =
        upload(assignment, [{"shots/home.png", <<137, 80, 78, 71, 0>>}, {"shots/menu.png", "m"}])

      {:ok, _job} = finish_agent(assignment, blobs, %{"shots/.x" => "is not a name"})

      version = Artifacts.latest(context.ticket.id, "shots/home.png")
      assert version.version == 1
      assert {:ok, <<137, 80, 78, 71, 0>>} = Artifacts.content(version)
      assert %{"kind" => "job", "id" => id} = version.author
      assert id == job.id
      assert Artifacts.latest(context.ticket.id, "shots/menu.png")

      # What could not be kept is on the record, with why.
      assert %{payload: %{"invalid_blobs" => %{"shots/.x" => "is not a name"}}} =
               job.id |> Events.for_job() |> Enum.find(&(&1.type == "job.finished"))
    end

    # What the worker reports is not a guard: a key outside the job's own, a group it did not
    # declare, and a name that is not one are each left unrecorded.
    test "records nothing the job could not have written", context do
      [job] = Jobs.for_ticket(context.ticket.id)
      assignment = FakeWorker.assign(job, context.worker)

      {:ok, _info} = Storage.put("job/someone-else/out-x/1", "theirs")
      [{"shots/ok.png", ok}] = assignment |> upload([{"shots/ok.png", "ok"}]) |> Map.to_list()

      blobs = %{
        "shots/ok.png" => ok,
        "shots/stolen.png" => %{"key" => "job/someone-else/out-x/1", "size" => 6},
        "undeclared/a.png" => ok,
        "shots/../x" => ok,
        "shots" => ok
      }

      {:ok, _job} = finish_agent(assignment, blobs)

      names = context.ticket.id |> Artifacts.list() |> Enum.map(& &1.name)
      assert "shots/ok.png" in names

      refute Enum.any?(
               names,
               &(&1 in ["shots/stolen.png", "undeclared/a.png", "shots/../x", "shots"])
             )
    end

    # The same rule for the transcript the result names: a key outside the job's own is not
    # recorded as its transcript, whatever the worker says.
    test "a transcript under another job's key is not recorded as this one's", context do
      [job] = Jobs.for_ticket(context.ticket.id)
      assignment = FakeWorker.assign(job, context.worker)
      {:ok, _info} = Storage.put("job/someone-else/transcript-1.jsonl", "theirs")

      written = %{
        "implementation.md" => "---\noutcome: done\n---\n# Done\n",
        "commit-message" => "Land the change\n"
      }

      result = FakeWorker.result(assignment, "success", written: written)

      {:ok, _job} =
        Jobs.complete(job.id, %{result | transcript: "job/someone-else/transcript-1.jsonl"})

      assert Artifacts.latest(context.ticket.id, "transcript-implementing-1.jsonl") == nil
    end

    test "is not recorded from a run that stopped on a question", context do
      [job] = Jobs.for_ticket(context.ticket.id)
      assignment = FakeWorker.assign(job, context.worker)
      blobs = upload(assignment, [{"shots/a.png", "a"}])

      FakeWorker.put_transcript(assignment)
      result = FakeWorker.result(assignment, "blocking", doc: "implementation.md")
      assert %Result{status: :waiting} = result
      {:ok, _job} = Jobs.complete(assignment["job_id"], %{result | blobs: blobs})

      assert Artifacts.latest(context.ticket.id, "shots/a.png") == nil
    end
  end

  # The operator's flow: a packaging command builds what a person downloads and tries.
  test "a packaging command's build is on the ticket for the tester", context do
    [job] = Jobs.for_ticket(context.ticket.id)
    assignment = FakeWorker.assign(job, context.worker)
    {:ok, _job} = finish_agent(assignment, %{})

    ticket = Tickets.get!(context.ticket.id)
    assert ticket.state == "packaging"
    [package] = Jobs.commands_for_ticket(ticket.id)
    assert Jobs.spec(package).command["outputs"] == ["pkg/*"]

    command = FakeWorker.assign(package, context.worker)
    assert %{"prefix" => _prefix, "token" => _token} = command["outputs"]
    blobs = upload(command, [{"pkg/app.tar.gz", <<31, 139, 8, 0>>}])

    {:ok, _info} = Storage.put(command["store"]["log_key"], "packed\n")

    {:ok, _job} =
      Jobs.complete(command["job_id"], %Result{
        status: :finished,
        outcome: :converged,
        exit_status: 0,
        log: command["store"]["log_key"],
        blobs: blobs
      })

    assert Tickets.get!(ticket.id).state == "human_testing"

    assert {:ok, <<31, 139, 8, 0>>} =
             ticket.id |> Artifacts.latest("pkg/app.tar.gz") |> Artifacts.content()

    assert {:ok, "packed\n"} = ticket.id |> Artifacts.latest("package.log") |> Artifacts.content()
  end

  # A release from before groups reads `shots/*` as a document it never finds, and ends every such
  # job `error` however well it went (`docs/design/commands.md` § Worker pools).
  # Groups arrived in protocol 2. Every agent now asks for 3, which is more — so what this holds is
  # that a job writing a group is never offered to a release from before groups.
  test "a job that writes a group asks for a worker that speaks protocol 2 or later", context do
    [job] = Jobs.for_ticket(context.ticket.id)
    assert Jobs.spec(job).may_invoke == %{}
    assert Jobs.protocol(job) >= 2
  end

  # A workflow job, not a chat: a chat's is hard-wired empty, and would pass whatever this did.
  test "a job that declares no group is given nowhere to put one" do
    {:ok, plain} =
      register_owned!(%{
        name: "none-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    user = member_fixture(plain)
    funded!(plain)
    {:ok, ticket} = Tickets.admit(plain, %{title: "t", body: "."}, {:user, user.id})
    [job] = Jobs.for_ticket(ticket.id)
    assert Jobs.spec(job).kind == :workflow

    refute Map.has_key?(FakeWorker.assign(job, FakeWorker.connect()), "outputs")
  end
end
