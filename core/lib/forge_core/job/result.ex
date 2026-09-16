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
          status: :waiting | :finished,
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
      "invalid" => Map.new(result.invalid, fn {name, why} -> {name, inspect(why)} end),
      "missing" => result.missing,
      "undeclared" => result.undeclared,
      "proposals" =>
        Map.new(result.proposals, fn {name, proposal} -> {name, proposal_to_map(proposal)} end),
      "invalid_proposals" => result.invalid_proposals,
      "harness" => result.harness
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
      questions: Enum.map(get.(:questions) || [], &question_from_map/1),
      documents:
        Map.new(get.(:documents) || %{}, fn {name, doc} -> {name, doc_from_map(doc)} end),
      invalid: get.(:invalid) || %{},
      missing: get.(:missing) || [],
      undeclared: get.(:undeclared) || [],
      proposals:
        Map.new(get.(:proposals) || %{}, fn {name, p} -> {name, proposal_from_map(p)} end),
      invalid_proposals: get.(:invalid_proposals) || %{},
      harness: get.(:harness) || %{}
    }
  end

  # `status` decides what the platform does with the row, so an unrecognised one is a bug to
  # hear about rather than a value to carry.
  defp status(status) when status in ["waiting", :waiting], do: :waiting
  defp status(status) when status in ["finished", :finished], do: :finished
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
      front_matter: get.(:front_matter) || %{},
      outcome: get.(:outcome),
      body: get.(:body) || "",
      questions: Enum.map(get.(:questions) || [], &question_from_map/1),
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

  defp question_to_map(%Question{} = question), do: Map.from_struct(question)

  defp question_from_map(question) do
    get = fn key -> Map.get(question, to_string(key), Map.get(question, key)) end

    %Question{
      key: get.(:key),
      text: get.(:text),
      anchor: get.(:anchor),
      options: get.(:options) || [],
      default: get.(:default),
      blocking: get.(:blocking) || false,
      assumption: get.(:assumption),
      line: get.(:line)
    }
  end
end
