defmodule ForgeWorker.Harness do
  @moduledoc """
  What an execution harness driver provides. Everything harness-specific lives behind this:
  how to start the process and how to turn its output into the platform's events.
  """

  alias ForgeCore.Job.Spec

  @typedoc "A normalised event: `type` without the `job.harness.` prefix, and a payload."
  @type event :: %{type: String.t(), payload: map()}

  @typedoc """
  Options a runner passes through: `:executable`, `:credential`, `:resume_session`, `:model`.
  `:credential` is `{:api_key, value}`, `{:oauth, value}`, or a zero-arity function
  returning one, so the secret never sits in process state or crash reports.
  """
  @type opts :: keyword()

  @doc "Capabilities the engine may rely on, e.g. `%{resume: true, permission_prompting: false}`."
  @callback capabilities() :: %{atom() => boolean()}

  @doc """
  The executable, its arguments and environment for running `spec` in `job_dir`. An env
  value may be a string, `{:secret, string}` (kept out of argv and logs), or `false` (must
  be absent).
  """
  @callback command(Spec.t(), String.t(), opts()) ::
              {String.t(), [String.t()],
               [{String.t(), String.t() | {:secret, String.t()} | false}]}

  @doc """
  Normalises one stdout line into zero or more events. Must never raise. Events of type
  `"started"` and `"finished"` are the ones the runner reads back.
  """
  @callback parse_line(String.t()) :: [event()]
end
