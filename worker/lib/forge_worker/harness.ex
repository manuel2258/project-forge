defmodule ForgeWorker.Harness do
  @moduledoc """
  What an execution harness driver provides. Everything harness-specific lives behind this:
  how to start the process and how to turn its output into the platform's events.
  """

  alias ForgeCore.Job.Spec

  @typedoc "A normalised event: `type` without the `job.harness.` prefix, and a payload."
  @type event :: %{type: String.t(), payload: map()}

  @typedoc "Options a runner passes through: `:executable`, `:credential`, `:resume_session`, `:model`."
  @type opts :: keyword()

  @doc "Capabilities the engine may rely on, e.g. `%{resume: true, permission_prompting: false}`."
  @callback capabilities() :: %{atom() => boolean()}

  @doc "The executable, its arguments and extra environment for running `spec` in `job_dir`."
  @callback command(Spec.t(), String.t(), opts()) ::
              {String.t(), [String.t()], [{String.t(), String.t() | false}]}

  @doc "Normalises one stdout line into zero or more events. Must never raise."
  @callback parse_line(String.t()) :: [event()]

  @doc "The event type that carries the harness's final result, if this line produced one."
  @callback finished_type() :: String.t()
end
