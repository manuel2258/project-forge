defmodule ForgeWorker.Harness do
  @moduledoc """
  What an execution harness driver provides. Everything harness-specific lives behind this:
  how to start the process and how to turn its output into the platform's events.
  """

  alias ForgeCore.Job.Spec

  @typedoc "A normalised event: `type` without the `job.harness.` prefix, and a payload."
  @type event :: %{type: String.t(), payload: map()}

  @typedoc """
  Options a runner passes through: `:executable`, `:credential`, `:resume_session`, `:model`,
  `:mode` and `:max_cost`. `:credential` is `{:api_key, value}`, `{:oauth, value}`, or a
  zero-arity function returning one, so the secret never sits in process state or crash reports —
  which is how a job's own credential arrives, sealed until the function runs
  (`ForgeWorker.Job.Credential`).

  `:mode` is `:prompt` (the default: one prompt on stdin, one result, the process exits) or
  `:streaming` (stdin stays open and takes many messages, one result each). A conversation is
  the second; `docs/design/conversations.md` § The harness supports this directly.

  `:max_cost` is the ceiling for this invocation in dollars. In `:prompt` mode it comes from the
  spec's budget; in `:streaming` mode there is no spec budget to take it from, so the caller
  passes what is left of the day.
  """
  @type opts :: keyword()

  @typedoc "How the process is fed. See `t:opts/0`."
  @type mode :: :prompt | :streaming

  @doc """
  Capabilities the engine may rely on, e.g. `%{resume: true, permission_prompting: false}`.
  `:streaming_input` says the driver can be written to after it starts — a runner asked for a
  conversation refuses a harness without it rather than starting one that can never be spoken to.
  """
  @callback capabilities() :: %{atom() => boolean()}

  @typedoc """
  What this machine can offer, as `ready` reports it: which harness, which version, and the
  aliases its CLI resolves. See `docs/design/worker-channel.md` § What a worker offers.

  **Nothing about an account.** It used to carry `login` and `models`, both answered with the
  machine's own token; a machine holds none now, and the platform asks the provider once per
  credential when it is saved (`docs/design/credentials.md` § Checked on save).
  """
  @type offer :: %{
          driver: String.t(),
          name: String.t(),
          version: String.t() | nil,
          aliases: [String.t()]
        }

  @doc """
  The harness's name on the wire — what a credential names as its `harness`, and what the
  platform matches a job against. Its own callback, so it can be said when `probe/1` cannot.
  """
  @callback driver() :: String.t()

  @doc """
  Asks the machine what it can offer. Takes the same opts as `command/3`.

  Must never raise and must always answer: a binary that is missing reports a `nil` version,
  because a worker that cannot describe itself is still a worker that can run work.
  """
  @callback probe(opts()) :: offer()

  @doc """
  Encodes one user message as the bytes to write to the process's stdin, newline included.

  Only meaningful in `:streaming` mode, and only a driver that reports `streaming_input` is
  asked for it.
  """
  @callback encode_message(String.t()) :: iodata()

  @doc """
  Encodes a request to end the turn in flight while leaving the process running, newline
  included. `request_id` correlates the acknowledgement the harness writes back.

  This is not the channel's `cancel`, which ends the process. For a conversation the process is
  the thing being kept — see `docs/design/conversations.md` § Turns.
  """
  @callback encode_interrupt(String.t()) :: iodata()

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
