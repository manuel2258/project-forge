defmodule ForgeCore.Job.Result do
  @moduledoc """
  What a finished or waiting job run produced, ready for the platform to record.

  It lives in core rather than in the worker because it is the wire: the worker builds one
  and sends it over the channel, the platform receives one and records it, and neither
  compiles the other. `to_map/1` and `from_map/1` are that crossing, and they are lossless —
  a result that survived a round trip must record exactly as the one that did not.

  `transcript` is the store key the run's transcript was uploaded to. `transcript_path` and
  `stderr_path` are the worker's own paths: they cross the wire because losing them would
  make the round trip lossy, and the platform must not open them — once the two are separate
  machines, they name files it does not have.
  """

  alias ForgeCore.Document
  alias ForgeCore.Document.Question
  alias ForgeCore.Document.Question.Option
  alias ForgeCore.Error
  alias ForgeCore.Proposal

  @enforce_keys [:status]
  defstruct [
    :status,
    :outcome,
    :declared_outcome,
    :reason,
    :killed,
    :exit_status,
    :transcript_path,
    :transcript,
    :stderr_path,
    # A parked run: the commit it pushed before it stopped, which every command it asked for runs
    # against (`docs/design/commands.md` § The ensured commit), and a file it wrote that could not
    # be read as invocations.
    :commit,
    :invocation_error,
    # A command's run: the store key its combined output was uploaded to, and how long it took.
    :log,
    :duration_ms,
    # What a parked run asked to invoke: `%{"command" => name, "args" => [string]}` each.
    invocations: [],
    # A run's groups of files, by artifact name (`package/app.tar.gz`): `%{"key", "size"}` once
    # uploaded — or `%{"path"}`, the worker's own staged copy, between collecting and uploading,
    # which the worker replaces before the result leaves it. And the files that could not be
    # kept, with why (`docs/design/job-prompt.md` § Groups of files).
    blobs: %{},
    invalid_blobs: %{},
    questions: [],
    documents: %{},
    invalid: %{},
    missing: [],
    undeclared: [],
    # Ticket proposals the run wrote to `out/proposals/`, keyed by filename, and the ones that
    # could not be read, keyed the same way with the reason already formatted as text. Both are
    # reported because neither fails the job: a proposal is not in `produces` and carries no
    # outcome, so a malformed one is kept and shown rather than dropped or turned into an
    # `error`. See `docs/design/ticket-proposals.md` § Malformed degrades, never drops.
    #
    # `%{"reason" => text, "raw" => text | nil}` per file. The reason is formatted rather than a
    # list of `ForgeCore.Error` structs, unlike `invalid` above, because it is shown to the
    # person deciding what to do with the proposal rather than read in a log — and `raw` is what
    # the agent actually wrote, which the platform keeps as a version so that a proposal it
    # cannot read is still a proposal a person can see and decline.
    proposals: %{},
    invalid_proposals: %{},
    harness: %{}
  ]

  @type t :: %__MODULE__{
          status: :waiting | :finished | :parked,
          commit: String.t() | nil,
          invocation_error: String.t() | nil,
          log: String.t() | nil,
          duration_ms: non_neg_integer() | nil,
          invocations: [%{String.t() => term()}],
          blobs: %{String.t() => %{String.t() => term()}},
          invalid_blobs: %{String.t() => String.t()},
          outcome: ForgeCore.Job.Outcome.outcome() | nil,
          declared_outcome: String.t() | nil,
          reason: String.t() | nil,
          killed: nil | :operator | :wall_clock,
          exit_status: integer() | nil,
          transcript_path: String.t() | nil,
          transcript: String.t() | nil,
          stderr_path: String.t() | nil,
          questions: [Question.t()],
          documents: %{String.t() => Document.t()},
          invalid: %{String.t() => term()},
          missing: [String.t()],
          undeclared: [String.t()],
          proposals: %{String.t() => Proposal.t()},
          invalid_proposals: %{String.t() => %{String.t() => String.t() | nil}},
          harness: map()
        }

  @doc "A JSON-encodable map. Atoms become strings; `from_map/1` puts them back."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      "status" => to_string(result.status),
      "outcome" => result.outcome && to_string(result.outcome),
      "declared_outcome" => result.declared_outcome,
      "reason" => result.reason,
      "killed" => result.killed && to_string(result.killed),
      "exit_status" => result.exit_status,
      "transcript" => result.transcript,
      "transcript_path" => result.transcript_path,
      "stderr_path" => result.stderr_path,
      "questions" => Enum.map(result.questions, &question_to_map/1),
      "documents" => Map.new(result.documents, fn {name, doc} -> {name, doc_to_map(doc)} end),
      "invalid" => Map.new(result.invalid, fn {name, why} -> {name, Error.to_text(why)} end),
      "missing" => result.missing,
      "undeclared" => result.undeclared,
      "proposals" =>
        Map.new(result.proposals, fn {name, proposal} -> {name, proposal_to_map(proposal)} end),
      "invalid_proposals" => result.invalid_proposals,
      "harness" => result.harness,
      "commit" => result.commit,
      "invocation_error" => result.invocation_error,
      "invocations" => result.invocations,
      "log" => result.log,
      "duration_ms" => result.duration_ms,
      "blobs" => result.blobs,
      "invalid_blobs" => result.invalid_blobs
    }
  end

  @doc "Rebuilds a result from `to_map/1`'s output, with string or atom keys."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    get = fn key -> Map.get(map, to_string(key), Map.get(map, key)) end

    %__MODULE__{
      status: status(get.(:status)),
      outcome: outcome(get.(:outcome)),
      declared_outcome: get.(:declared_outcome),
      reason: get.(:reason),
      killed: killed(get.(:killed)),
      exit_status: get.(:exit_status),
      transcript: get.(:transcript),
      transcript_path: get.(:transcript_path),
      stderr_path: get.(:stderr_path),
      questions: Enum.map(or_default(get, :questions, []), &question_from_map/1),
      documents:
        Map.new(or_default(get, :documents, %{}), fn {name, doc} -> {name, doc_from_map(doc)} end),
      invalid: or_default(get, :invalid, %{}),
      missing: or_default(get, :missing, []),
      undeclared: or_default(get, :undeclared, []),
      proposals:
        Map.new(or_default(get, :proposals, %{}), fn {name, p} -> {name, proposal_from_map(p)} end),
      invalid_proposals: or_default(get, :invalid_proposals, %{}),
      harness: or_default(get, :harness, %{}),
      commit: get.(:commit),
      invocation_error: get.(:invocation_error),
      invocations: or_default(get, :invocations, []),
      log: get.(:log),
      duration_ms: get.(:duration_ms),
      blobs: or_default(get, :blobs, %{}),
      invalid_blobs: or_default(get, :invalid_blobs, %{})
    }
  end

  # A key the map leaves out comes back as its empty value, never nil: every caller folds over it.
  # A function rather than `||` inline, which Credo counts as a branch each.
  defp or_default(get, key, default), do: get.(key) || default

  # `status` decides what the platform does with the row, so an unrecognised one is a bug to
  # hear about rather than a value to carry.
  defp status(status) when status in ["waiting", :waiting], do: :waiting
  defp status(status) when status in ["finished", :finished], do: :finished
  defp status(status) when status in ["parked", :parked], do: :parked
  defp status(other), do: raise(ArgumentError, "unknown job result status: #{inspect(other)}")

  # Atoms are listed rather than converted: `String.to_existing_atom/1` would depend on what
  # the receiving node happens to have loaded, which is not a property of the wire.
  @outcomes ~w(converged did_not_converge budget_exhausted error cancelled)a
  @killed ~w(operator wall_clock)a

  defp outcome(value), do: known(value, @outcomes)
  defp killed(value), do: known(value, @killed)

  defp known(nil, _allowed), do: nil

  defp known(value, allowed) do
    Enum.find(allowed, fn atom -> atom == value or to_string(atom) == value end) ||
      raise(ArgumentError, "unknown value #{inspect(value)}, expected one of #{inspect(allowed)}")
  end

  defp doc_to_map(%Document{} = doc) do
    %{
      "front_matter" => doc.front_matter,
      "outcome" => doc.outcome,
      "body" => doc.body,
      "questions" => Enum.map(doc.questions, &question_to_map/1),
      "raw" => doc.raw
    }
  end

  defp doc_from_map(doc) do
    get = fn key -> Map.get(doc, to_string(key), Map.get(doc, key)) end

    %Document{
      front_matter: or_default(get, :front_matter, %{}),
      outcome: get.(:outcome),
      body: get.(:body) || "",
      questions: Enum.map(or_default(get, :questions, []), &question_from_map/1),
      raw: get.(:raw) || ""
    }
  end

  # String keys spelled out, like `doc_to_map/1` above and unlike `Map.from_struct/1`. The wire
  # is JSON, so a struct's atom keys arrive as strings on the far side: a caller reading the
  # payload before it has been encoded sees different keys from one reading it after, and only
  # one of the two has a test. `from_map/1` accepts either, so this is about what is *sent*.
  defp proposal_to_map(%Proposal{} = proposal) do
    %{"title" => proposal.title, "body" => proposal.body, "raw" => proposal.raw}
  end

  defp proposal_from_map(map) do
    get = fn key -> Map.get(map, to_string(key), Map.get(map, key)) end

    %Proposal{title: get.(:title), body: get.(:body), raw: get.(:raw)}
  end

  # Options are structs too, and a struct nested in `Map.from_struct/1` reaches the JSON encoder,
  # which refuses one it has no implementation for.
  defp question_to_map(%Question{} = question) do
    question
    |> Map.from_struct()
    |> Map.update!(:options, fn options -> Enum.map(options, &Option.to_map/1) end)
  end

  defp question_from_map(question) do
    get = fn key -> Map.get(question, to_string(key), Map.get(question, key)) end

    %Question{
      key: get.(:key),
      text: get.(:text),
      anchor: get.(:anchor),
      options: get |> or_default(:options, []) |> Enum.map(&Option.from_map/1),
      blocking: get.(:blocking) || false,
      assumption: get.(:assumption),
      line: get.(:line)
    }
  end
end
