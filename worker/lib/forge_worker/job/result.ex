defmodule ForgeWorker.Job.Result do
  @moduledoc "What a finished or waiting job run produced, ready for the platform to record."

  alias ForgeCore.Document
  alias ForgeCore.Document.Question

  @enforce_keys [:status]
  defstruct [
    :status,
    :outcome,
    :declared_outcome,
    :reason,
    :killed,
    :exit_status,
    :transcript_path,
    :stderr_path,
    questions: [],
    documents: %{},
    invalid: %{},
    missing: [],
    undeclared: [],
    harness: %{}
  ]

  @type t :: %__MODULE__{
          status: :waiting | :finished,
          outcome: ForgeCore.Job.Outcome.outcome() | nil,
          declared_outcome: String.t() | nil,
          reason: String.t() | nil,
          killed: nil | :operator | :wall_clock,
          exit_status: integer() | nil,
          transcript_path: String.t(),
          stderr_path: String.t(),
          questions: [Question.t()],
          documents: %{String.t() => Document.t()},
          invalid: %{String.t() => term()},
          missing: [String.t()],
          undeclared: [String.t()],
          harness: map()
        }
end
