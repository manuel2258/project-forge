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
  `:effort`, `:mode` and `:max_tokens`. `:credential` is `{:api_key, value}`, `{:oauth, value}`, or a
  zero-arity function returning one, so the secret never sits in process state or crash reports —
  which is how a job's own credential arrives, sealed until the function runs
  (`ForgeWorker.Job.Credential`).

  `:mode` is `:prompt` (the default: one prompt on stdin, one result, the process exits) or
  `:streaming` (stdin stays open and takes many messages, one result each). A conversation is
  the second; `docs/design/conversations.md` § The harness supports this directly.

  `:max_tokens` is a conversation's ceiling in weighted tokens: in `:streaming` mode there is no spec
  budget to take one from, so the caller passes what is left of the day. In `:prompt` mode the
  runner reads the spec's. Neither is passed to the harness: forge counts and stops the process
  itself (`ForgeWorker.Job.Meter`).

  A driver reports each model call as a `usage` event (`message_id`, `tokens` by kind).
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
  aliases its CLI resolves and the effort levels it takes. See `docs/design/worker-channel.md`
  § What a worker offers.

  **Nothing about an account.** It used to carry `login` and `models`, both answered with the
  machine's own token; a machine holds none now, and the platform asks the provider once per
  credential when it is saved (`docs/design/credentials.md` § Checked on save).
  """
  @type offer :: %{
          driver: String.t(),
          name: String.t(),
          version: String.t() | nil,
          aliases: [String.t()],
          efforts: [String.t()]
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

  # -- harnesses that keep a conversation of their own with the process --------------------------
  #
  # Claude Code is spoken to in lines that mean the same whenever they are written, so `parse_line/1`
  # and `encode_message/1` need no memory. Codex's app-server is JSON-RPC: a request is answered by
  # a response that says which request it was, a thread has to exist before a turn can start in it,
  # and a message sent while a turn is running has to wait for it. That is state, and it belongs to
  # the driver (`docs/design/codex.md` § The driver) — so a driver may implement the callbacks
  # below, and a runner calls them through the functions after them, which fall back to the
  # stateless callbacks. **Claude Code implements none of them and behaves exactly as before.**

  @typedoc "A driver's own state, opaque to the runner. `nil` for a driver that keeps none."
  @type state :: term()

  @doc """
  The driver's starting state and the bytes to write to the process as soon as it is spawned
  (for Codex, `initialize`). Receives the harness opts: model, effort, the session to resume.
  """
  @callback init(opts()) :: {iodata(), state()}

  @doc """
  One stdout line: the events it carries, the bytes to write back in answer, and the new state.
  Must never raise, as `parse_line/1` must not.
  """
  @callback handle_line(String.t(), state()) :: {[event()], iodata(), state()}

  @doc "A user message: the bytes to write now (none when it has to wait), and the new state."
  @callback send_message(String.t(), state()) :: {iodata(), state()}

  @doc "An interrupt of the turn in flight: the bytes to write, and the new state."
  @callback interrupt(String.t(), state()) :: {iodata(), state()}

  @optional_callbacks init: 1, handle_line: 2, send_message: 2, interrupt: 2

  @doc "Whether `module` keeps a conversation of its own with the process."
  @spec stateful?(module()) :: boolean()
  def stateful?(module) do
    Code.ensure_loaded(module)
    function_exported?(module, :handle_line, 2)
  end

  @doc "The driver's starting state and its first bytes; nothing to write for a stateless one."
  @spec init(module(), opts()) :: {iodata(), state()}
  def init(module, opts) do
    if stateful?(module), do: module.init(opts), else: {[], nil}
  end

  @doc "`handle_line/2`, or `parse_line/1` with nothing to write for a stateless driver."
  @spec handle_line(module(), String.t(), state()) :: {[event()], iodata(), state()}
  def handle_line(module, line, state) do
    if stateful?(module),
      do: module.handle_line(line, state),
      else: {module.parse_line(line), [], state}
  end

  @doc "`send_message/2`, or `encode_message/1` for a stateless driver."
  @spec send_message(module(), String.t(), state()) :: {iodata(), state()}
  def send_message(module, text, state) do
    if stateful?(module),
      do: module.send_message(text, state),
      else: {module.encode_message(text), state}
  end

  @doc "`interrupt/2`, or `encode_interrupt/1` for a stateless driver."
  @spec interrupt(module(), String.t(), state()) :: {iodata(), state()}
  def interrupt(module, request_id, state) do
    if stateful?(module),
      do: module.interrupt(request_id, state),
      else: {module.encode_interrupt(request_id), state}
  end

  # -- which harness -------------------------------------------------------------------------

  @drivers %{
    "claude_code" => ForgeWorker.Harness.ClaudeCode,
    "codex" => ForgeWorker.Harness.Codex
  }

  @doc """
  What this machine's configured options mean to `module`. `FORGE_CLAUDE_EXECUTABLE`, `_MODEL` and
  `_EFFORT` are Claude Code's: handed to Codex they made it run `claude app-server` and send
  `opus` as its model, so they are dropped for Codex; every other driver (Claude Code, today the
  only one) gets them as configured. Codex's own binary is `:codex_executable`.
  """
  @spec machine_opts(keyword(), module()) :: keyword()
  def machine_opts(opts, ForgeWorker.Harness.Codex),
    do: Keyword.drop(opts, [:executable, :model, :effort])

  def machine_opts(opts, _module), do: opts

  @doc "The harnesses this release can drive, by the name the platform gives them."
  @spec drivers() :: %{String.t() => module()}
  def drivers, do: @drivers

  @doc """
  The driver an assignment asks for: the one it names, and Claude Code (or whatever this machine is
  configured to run) for one that names none, which is every assignment from before a job had a
  harness. A name this release does not know is `nil`, and the caller refuses the job.
  """
  @spec for_assignment(map(), module()) :: module() | nil
  def for_assignment(%{"harness" => name}, _default) when is_binary(name),
    do: Map.get(@drivers, name)

  def for_assignment(_assignment, default), do: default
end
