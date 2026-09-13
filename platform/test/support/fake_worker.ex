defmodule Forge.FakeWorker do
  @moduledoc """
  A worker as the platform sees one, without a machine behind it. The calling test process
  registers itself as a connected worker, receives assignments, and answers them with results
  it builds the way a real worker does — by collecting what the agent wrote and asking
  `ForgeCore.Job.Outcome` how the run ended.

  This is what the platform's end-to-end tests use now that the worker is not compiled in.
  The scenarios mirror `worker/test/support/fake_claude.sh`, which is where the other half of
  the loop — harness output to a result — is tested.
  """

  import ExUnit.Assertions

  alias Forge.{Jobs, Storage, Workers}
  alias ForgeCore.Document
  alias ForgeCore.Job.{Outcome, Result, Spec}

  @big_budget 64 * 1024 * 1024 * 1024
  @transcript ~s({"type":"system","subtype":"init","session_id":"sess-42"}\n)
  @harness %{
    "session_id" => "sess-42",
    "model" => "fake-model",
    "subtype" => "success",
    "is_error" => false,
    "turns" => 3,
    "cost_usd" => 0.0421,
    "duration_ms" => 1234,
    "usage" => %{"input_tokens" => 10, "output_tokens" => 20},
    "exit_status" => 0
  }

  @doc """
  Creates a ready worker and registers the calling process as its connection, so assignments
  arrive as `{:assign, payload}` messages in this process's mailbox.
  """
  @spec connect(keyword()) :: Forge.Workers.Worker.t()
  def connect(opts \\ []) do
    {:ok, worker, _token} = Workers.create(%{provider: "fake"})
    {:ok, worker} = Workers.ready(worker, Keyword.get(opts, :memory_budget, @big_budget))
    :ok = Workers.connected(worker.id)
    worker
  end

  @doc "Assigns `job` to `worker` and returns the assignment the worker was sent."
  @spec assign(Forge.Jobs.Job.t(), Forge.Workers.Worker.t()) :: map()
  def assign(job, worker) do
    {:ok, _job} = Jobs.assign(job, worker)
    take_assignment(job.id)
  end

  @doc "The assignment for `job_id`, which is already in this process's mailbox."
  @spec take_assignment(String.t()) :: map()
  def take_assignment(job_id) do
    assert_receive {:assign, %{"job_id" => ^job_id} = assignment}, 1_000
    assignment
  end

  @doc "Sends one harness event the way the channel does, prefix and all."
  @spec event(map(), String.t(), map()) :: :ok
  def event(assignment, type, payload \\ %{}),
    do:
      Jobs.record_harness_event(assignment["job_id"], %{
        type: "job.harness." <> type,
        payload: payload
      })

  @doc """
  Answers an assignment: uploads a transcript to the key the platform minted a token for, and
  records the result `scenario` produces. Options: `:doc` (the document the agent writes,
  default `plan.md`), `:harness` (overrides), `:transcript` (false to send none).
  """
  @spec finish(map(), String.t(), keyword()) :: {:ok, Forge.Jobs.Job.t()} | {:error, term()}
  def finish(assignment, scenario \\ "success", opts \\ []) do
    case Keyword.get(opts, :commit) do
      nil -> :ok
      {path, content} -> commit(assignment, path, content)
    end

    if Keyword.get(opts, :transcript, true), do: put_transcript(assignment)

    # A real run streams events before it ends. These two are what the timeline needs to have
    # something in it, and what proves the platform is writing what the channel brings.
    if Keyword.get(opts, :events, true) do
      event(assignment, "started", %{"model" => "fake-model", "session_id" => "sess-42"})
      event(assignment, "text", %{"text" => "Reading the plan."})
      event(assignment, "tool_use", %{"name" => "Read", "input" => %{"path" => "plan.md"}})
      event(assignment, "finished", %{"subtype" => "success"})
    end

    Jobs.complete(assignment["job_id"], result(assignment, scenario, opts))
  end

  @doc "Assign and answer in one go, which is what most tests want."
  @spec run(Forge.Jobs.Job.t(), Forge.Workers.Worker.t(), String.t(), keyword()) ::
          {:ok, Forge.Jobs.Job.t()} | {:error, term()}
  def run(job, worker, scenario \\ "success", opts \\ []) do
    job |> assign(worker) |> finish(scenario, opts)
  end

  @doc "Uploads a transcript, as the worker does before it sends a result."
  @spec put_transcript(map(), String.t()) :: :ok
  def put_transcript(assignment, content \\ @transcript) do
    {:ok, _info} = Storage.put(assignment["store"]["transcript_key"], content)
    :ok
  end

  @doc """
  Commits a file on the ticket branch and pushes it over the platform's git endpoint, with the
  credential the assignment carries.

  This is the half of a run the result cannot stand in for: a `changeset` artifact points at a
  commit, and a merge acts on it, so a test about either needs the branch to have really moved.
  Using the assignment's own token rather than a fresh one is deliberate — it puts the ref scope
  the platform issued on the same path as everything else here.
  """
  @spec commit(map(), String.t(), String.t()) :: :ok
  def commit(assignment, path, content) do
    git = assignment["git"]
    dir = Path.join(Forge.GitFixtures.tmp_dir("fake-worker"), "clone")
    url = with_token(git["url"], git["token"])

    git!(Path.dirname(dir), ["clone", "--quiet", "--branch", git["branch"], url, dir])
    File.mkdir_p!(Path.dirname(Path.join(dir, path)))
    File.write!(Path.join(dir, path), content)
    git!(dir, ["add", path])

    git!(dir, [
      "-c",
      "user.name=forge",
      "-c",
      "user.email=forge@localhost",
      "commit",
      "-q",
      "-m",
      "#{assignment["spec"]["state"]}: attempt #{assignment["spec"]["attempt"]}"
    ])

    git!(dir, ["push", "--quiet", "--force", url, "HEAD:refs/heads/" <> git["branch"]])
    :ok
  end

  defp with_token(url, token),
    do: url |> URI.parse() |> Map.put(:userinfo, "forge:" <> token) |> URI.to_string()

  defp git!(dir, args), do: {:ok, _out} = Forge.Git.run(dir, args)

  @doc """
  The result a run of `scenario` produces, decided the way the worker decides it: from what
  the agent wrote, what the spec declared, and how the process ended.
  """
  @spec result(map(), String.t(), keyword()) :: Result.t()
  def result(assignment, scenario \\ "success", opts \\ []) do
    spec = Spec.from_map(assignment["spec"])
    harness = Map.merge(harness(scenario), Keyword.get(opts, :harness, %{}))
    written = written(scenario, Keyword.get(opts, :doc, "plan.md"))

    run =
      Map.merge(collect(spec, written), %{
        killed: nil,
        exit_status: harness["exit_status"],
        result: result_message(harness)
      })

    base = %Result{
      status: :finished,
      exit_status: run.exit_status,
      transcript: transcript_key(assignment, opts),
      documents: run.documents,
      invalid: run.invalid,
      missing: run.missing,
      undeclared: run.undeclared,
      harness: harness
    }

    case Outcome.decide(spec, run) do
      {:waiting, questions} ->
        %{base | status: :waiting, questions: questions}

      {:finished, outcome, declared, reason} ->
        %{base | outcome: outcome, declared_outcome: declared, reason: reason}
    end
  end

  defp transcript_key(assignment, opts) do
    if Keyword.get(opts, :transcript, true), do: assignment["store"]["transcript_key"]
  end

  defp result_message(%{"subtype" => nil}), do: nil
  defp result_message(harness), do: %{subtype: harness["subtype"], is_error: harness["is_error"]}

  # The harness summary each scenario ends with.
  defp harness("max_turns"),
    do: %{
      @harness
      | "subtype" => "error_max_turns",
        "is_error" => true,
        "turns" => 40,
        "cost_usd" => 1.5,
        "exit_status" => 1
    }

  # A runaway: it spends up to whatever budget it was handed and the harness stops it there.
  # The cost is the one the spec allowed, so a test can assert the cap bound rather than that
  # some number came back.
  defp harness("max_budget"),
    do: %{
      @harness
      | "subtype" => "error_max_budget_usd",
        "is_error" => true,
        "turns" => 7,
        "exit_status" => 1
    }

  # A run that never got going: no init event, so no model, and nothing to show for it. This
  # is what a resume whose session the harness could not find looks like.
  defp harness("no_start"),
    do: %{
      "session_id" => nil,
      "model" => nil,
      "subtype" => nil,
      "is_error" => nil,
      "turns" => nil,
      "cost_usd" => nil,
      "duration_ms" => nil,
      "usage" => nil,
      "exit_status" => 1
    }

  defp harness(_scenario), do: @harness

  # What the agent left in `out/`, by scenario. The shapes come from fake_claude.sh.
  defp written("success", name),
    do: %{name => "---\noutcome: done\n---\n# Plan\n\nDo the thing.\n"}

  defp written("plan_invalid", name),
    do: %{name => "---\noutcome: plan_invalid\n---\n# Plan\n\nThe plan cannot work.\n"}

  defp written("blocking", name),
    do: %{
      name => """
      ---
      outcome: done
      ---
      # Plan

      ```question
      key: backend
      text: Which backend?
      options: [a, b]
      default: a
      blocking: true
      ```
      """
    }

  defp written("undeclared", name),
    do: %{name => "---\noutcome: done\n---\n# Plan\n", "notes.md" => "scratch"}

  defp written("invalid_document", name), do: %{name => "---\noutcome: done\n"}
  # Stopped before it wrote anything: the budget and the turn limit both cut in mid-run.
  defp written(scenario, _name)
       when scenario in ["max_turns", "max_budget", "no_start", "nothing"],
       do: %{}

  defp written(scenario, _name),
    do: raise(ArgumentError, "unknown fake worker scenario #{inspect(scenario)}")

  # The same split `ForgeWorker.Job.Dir.collect/2` makes: declared documents that parsed,
  # declared ones that did not, declared ones that are missing, and files nobody declared.
  defp collect(%Spec{} = spec, written) do
    declared = Spec.document_outputs(spec)

    collected =
      Enum.reduce(written, %{documents: %{}, invalid: %{}, undeclared: []}, fn {name, content},
                                                                               acc ->
        case {name in declared, Document.parse(content)} do
          {false, _parsed} -> %{acc | undeclared: acc.undeclared ++ [name]}
          {true, {:ok, document}} -> %{acc | documents: Map.put(acc.documents, name, document)}
          {true, {:error, errors}} -> %{acc | invalid: Map.put(acc.invalid, name, errors)}
        end
      end)

    Map.put(collected, :missing, Enum.reject(declared, &Map.has_key?(written, &1)))
  end
end
