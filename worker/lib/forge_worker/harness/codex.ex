defmodule ForgeWorker.Harness.Codex do
  @moduledoc """
  The driver for OpenAI's Codex CLI, through its app-server: JSON-RPC over stdio
  (`docs/design/codex.md` § The driver).

  **Why the app-server and not `codex exec --json`:** forge stops a run itself, during the run,
  once its usage passes its budget, and that needs the token count after each model call. `exec`
  reports usage once, at the end. The app-server streams `thread/tokenUsage/updated` after each
  call, takes `turn/interrupt`, and resumes a thread.

  **Every message name in this module was written from OpenAI's published description of the
  app-server and not checked against an installed `codex`** — the machine this was written on had
  none (`docs/design/codex.md` § Not verified here). The fixtures under `test/support/` are
  written to the same description, and a first run against the real thing is what confirms or
  corrects them.

  The driver keeps a conversation of its own with the process (`ForgeWorker.Harness`'s stateful
  callbacks): `initialize`, then `thread/start` or `thread/resume`, then `turn/start`. A message
  sent while a turn is running is held and goes on `turn/completed`. In a job (prompt mode) the
  runner closes stdin at the first `turn/completed`; in a conversation the process lives on.
  """

  @behaviour ForgeWorker.Harness

  # The shell prefix that delivers a ChatGPT login: the JSON reaches the process through the
  # loader file as one variable (`ForgeWorker.Job.Exec`), is written to `auth.json` under umask
  # 077 where Codex reads it, unset, and Codex is `exec`ed — **never argv, never the unit**. A
  # token delivered the other way (`CODEX_ACCESS_TOKEN`) needs no file.
  @prefix ~S(umask 077; export CODEX_HOME="$HOME/.codex"; mkdir -p "$CODEX_HOME"; ) <>
            ~S(if [ -n "${FORGE_CODEX_AUTH-}" ]; then ) <>
            ~S(printf '%s' "$FORGE_CODEX_AUTH" > "$CODEX_HOME/auth.json"; fi; ) <>
            ~S(unset FORGE_CODEX_AUTH; exec "$@")

  @probe_timeout_ms 10_000
  # Declared, as Claude's are: the levels `codex` takes for `model_reasoning_effort`, weakest first.
  @efforts ~w(minimal low medium high)

  @impl true
  def driver, do: "codex"

  @impl true
  # A job's `HOME` is its own, so the thread a run made is carried the way Claude's session is: the
  # rollout file under `CODEX_HOME/sessions/` is uploaded, and put back before a resume
  # (`ForgeWorker.Job.Session`, `docs/design/codex.md` § Sessions). `session_layout: :rollout` says
  # where it lives; nothing outside `sessions/` is ever read, so `auth.json` cannot leave with it.
  def capabilities,
    do: %{
      resume: true,
      permission_prompting: false,
      streaming_input: true,
      session_layout: :rollout
    }

  @impl true
  def probe(opts) do
    %{
      driver: driver(),
      name: "Codex",
      version: version(executable(opts)),
      # Nothing in forge lists Codex's models: a new one needs nothing from forge, so the model is
      # free text and an empty one is Codex's own default (`docs/design/codex.md`).
      aliases: [],
      efforts: @efforts
    }
  end

  defp version(executable) do
    task =
      Task.async(fn ->
        try do
          System.cmd(executable, ["--version"], stderr_to_stdout: true)
        rescue
          _error -> :failed
        catch
          _kind, _reason -> :failed
        end
      end)

    case Task.yield(task, @probe_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      # `codex-cli 0.46.0`: the last word is the version.
      {:ok, {output, 0}} -> output |> String.split() |> List.last()
      _other -> nil
    end
  end

  # -- invocation -------------------------------------------------------------------------------

  @impl true
  def command(_spec, job_dir, opts) do
    exe = executable(opts)

    {"/bin/sh",
     ["-c", @prefix, "forge-codex", exe, "app-server", "-c", "check_for_update_on_startup=false"],
     [{"FORGE_JOB", job_dir}] ++ credential_env(resolve(Keyword.get(opts, :credential)))}
  end

  # Only Codex's own key: `:executable` is Claude Code's (`FORGE_CLAUDE_EXECUTABLE`), and reading it
  # here ran `claude app-server` on the image (`ForgeWorker.Harness.machine_opts/2`).
  defp executable(opts), do: Keyword.get(opts, :codex_executable, "codex")

  # Exactly one credential reaches the process, through the loader file and never the command
  # line; the other variable is explicitly absent.
  defp credential_env({:chatgpt_login, json}),
    do: [{"FORGE_CODEX_AUTH", {:secret, json}}, {"CODEX_ACCESS_TOKEN", false}]

  defp credential_env({:access_token, token}),
    do: [{"CODEX_ACCESS_TOKEN", {:secret, token}}, {"FORGE_CODEX_AUTH", false}]

  defp credential_env(nil), do: [{"CODEX_ACCESS_TOKEN", false}, {"FORGE_CODEX_AUTH", false}]

  defp resolve(fun) when is_function(fun, 0), do: fun.()
  defp resolve(credential), do: credential

  # -- the conversation with the process -------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      phase: :initializing,
      next_id: 1,
      # What wrote the rollout this run leaves: recorded with the session and compared with the
      # machine's before a resume, **and a session recorded with none is never resumed**
      # (`ForgeWorker.Job.Session`).
      version: version(executable(opts)),
      thread: Keyword.get(opts, :resume_session),
      resume?: is_binary(Keyword.get(opts, :resume_session)),
      model: blank_to_nil(Keyword.get(opts, :model)),
      effort: blank_to_nil(Keyword.get(opts, :effort)),
      turn: nil,
      busy: false,
      queue: [],
      requests: %{},
      last_usage: 0,
      last_limits: %{},
      messages: 0
    }

    {request(0, "initialize", %{
       "clientInfo" => %{"name" => "forge", "title" => "Forge", "version" => "0"}
     }), %{state | requests: %{0 => :initialize}}}
  end

  @impl true
  def send_message(text, %{phase: :ready, busy: false} = state), do: start_turn(text, state)
  def send_message(text, state), do: {[], %{state | queue: state.queue ++ [text]}}

  @impl true
  def interrupt(request_id, %{thread: thread, turn: turn} = state)
      when is_binary(thread) and is_binary(turn) do
    {request(request_id, "turn/interrupt", %{"threadId" => thread, "turnId" => turn}), state}
  end

  # Nothing to interrupt: no turn has started, so nothing is written (the runner then does not
  # mark the next turn as interrupted).
  def interrupt(_request_id, state), do: {[], state}

  @impl true
  def handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{} = message} ->
        message(message, state)

      {:ok, _other} ->
        {[event("malformed", %{raw: line, reason: "no object"})], [], state}

      {:error, _} ->
        {[event("malformed", %{raw: line, reason: "not JSON"})], [], state}
    end
  end

  # A response to something this driver asked.
  defp message(%{"id" => id} = message, state)
       when is_map_key(message, "result") or is_map_key(message, "error") do
    {kind, requests} = Map.pop(state.requests, id)
    response(kind, message, %{state | requests: requests})
  end

  defp message(%{"method" => method} = message, state),
    do: notification(method, message["params"] || %{}, state)

  defp message(other, state), do: {[event("unknown", %{type: nil, raw: other})], [], state}

  defp response(:initialize, %{"error" => _}, state), do: failed("initialize was refused", state)

  defp response(:initialize, _result, state) do
    # `initialized` is a notification: no id, no answer.
    {id, state} = next_id(state)
    method = if state.resume?, do: "thread/resume", else: "thread/start"

    params =
      %{"approvalPolicy" => "never", "sandbox" => "danger-full-access"}
      |> put_unless_nil("model", state.model)
      |> then(&if(state.resume?, do: Map.put(&1, "threadId", state.thread), else: &1))

    bytes = [notify("initialized", %{}), request(id, method, params)]
    {[], bytes, %{state | phase: :starting, requests: Map.put(state.requests, id, :thread)}}
  end

  defp response(:thread, %{"error" => _}, state),
    do: failed("the thread could not be started", state)

  defp response(:thread, %{"result" => result}, state) do
    thread = get_in(result, ["thread", "id"]) || state.thread
    state = %{state | thread: thread, phase: :ready}

    started =
      event("started", %{
        session_id: thread,
        model: get_in(result, ["model"]) || state.model,
        version: state.version,
        tools: [],
        raw: result
      })

    {bytes, state} = next_queued(state)
    {[started], bytes, state}
  end

  defp response(:turn, %{"error" => %{"message" => text}}, state),
    do: finish_turn("error_during_execution", true, to_string(text), state)

  defp response(:turn, _ok, state), do: {[], [], state}

  # An interrupt's answer, or one for something this driver no longer remembers.
  defp response(_other, _message, state), do: {[], [], state}

  # -- notifications ---------------------------------------------------------------------------

  defp notification("turn/started", params, state),
    do: {[], [], %{state | turn: get_in(params, ["turn", "id"]) || state.turn, busy: true}}

  defp notification("item/started", %{"item" => item}, state), do: {item_started(item), [], state}

  defp notification("item/completed", %{"item" => item}, state),
    do: {item_completed(item), [], state}

  # Each call's own usage, from the notification's `last` breakdown: fresh input is what was not
  # read from the cache, the cache read is `cachedInputTokens`, Codex has no cache write, and
  # output is as reported (reasoning is part of it, which a first run confirms). The id is the
  # running total, so a notification repeated with nothing new is the same call and is counted
  # once (`ForgeWorker.Job.Meter`).
  defp notification("thread/tokenUsage/updated", %{"tokenUsage" => usage}, state) do
    total = get_in(usage, ["total", "totalTokens"]) || 0
    last = usage["last"] || %{}
    input = whole(last["inputTokens"])
    cached = min(whole(last["cachedInputTokens"]), input)

    events =
      if total > state.last_usage do
        [
          event("usage", %{
            message_id: "codex-#{total}",
            parent_tool_use_id: nil,
            tokens: %{
              input: input - cached,
              cache_write: 0,
              cache_read: cached,
              output: whole(last["outputTokens"])
            }
          })
        ]
      else
        []
      end

    {events, [], %{state | last_usage: max(total, state.last_usage)}}
  end

  defp notification("thread/tokenUsage/updated", _params, state), do: {[], [], state}

  defp notification("account/rateLimits/updated", %{"rateLimits" => limits}, state) do
    events =
      for {key, type} <- [{"primary", "five_hour"}, {"secondary", "seven_day"}],
          %{} = window <- [limits[key]] do
        used = window["usedPercent"]

        event("rate_limit", %{
          status: if(is_number(used) and used >= 100, do: "rejected", else: "allowed"),
          resets_at: window["resetsAt"],
          rate_limit_type: type,
          utilization: if(is_number(used), do: used / 100),
          is_using_overage: false,
          windows: %{},
          raw: limits
        })
      end

    {events, [], %{state | last_limits: limits}}
  end

  defp notification("account/rateLimits/updated", _params, state), do: {[], [], state}

  defp notification("turn/completed", %{"turn" => turn}, state) do
    status = turn["status"]
    failed? = status in ["failed"]
    detail = get_in(turn, ["error", "message"])

    {events, bytes, state} =
      finish_turn(
        cond do
          failed? -> "error_during_execution"
          status == "interrupted" -> "error_during_execution"
          true -> "success"
        end,
        failed?,
        detail,
        state
      )

    {limit_events(detail, state) ++ events, bytes, state}
  end

  # An error that stops the run: a usage limit reads the same as Claude's does, so the job goes
  # back to pending rather than failing (`docs/design/credentials.md` § A limit reached mid-run).
  # Which messages OpenAI words that way is a thing to confirm against a real account.
  defp notification("error", params, state) do
    text = get_in(params, ["error", "message"]) || params["message"]
    {[event("notice", %{subtype: "error", raw: params})] ++ limit_events(text, state), [], state}
  end

  defp notification(method, params, state),
    do: {[event("notice", %{subtype: method, raw: params})], [], state}

  # What window stopped the run: the one the last report had at 100% (the later reset if both
  # were), failing that the fullest one reported, with its own reset. **Only when no window with a
  # reset was reported before the error** is there nothing to read, and then it is the five-hour
  # window ending five hours from now — **a guess**, there because without a reset the job would
  # fail instead of going back to pending. It assumes the five-hour wait is the shorter of the two
  # possible; if the limit was the weekly one the job returns after five hours, hits it again, and
  # that error comes with the weekly window's report.
  @fallback_wait_s 5 * 3600

  defp limit_events(text, state) when is_binary(text) do
    if Regex.match?(~r/usage limit|rate limit|limit reached/i, text) do
      {type, reset} = stopping_window(state.last_limits)

      [
        event("rate_limit", %{
          status: "rejected",
          resets_at: reset,
          rate_limit_type: type,
          utilization: nil,
          is_using_overage: false,
          windows: %{},
          raw: %{}
        })
      ]
    else
      []
    end
  end

  defp limit_events(_text, _state), do: []

  defp stopping_window(limits) do
    windows =
      for {key, type} <- [{"primary", "five_hour"}, {"secondary", "seven_day"}],
          %{} = window <- [limits[key]],
          is_integer(window["resetsAt"]),
          do: {type, window["resetsAt"], window["usedPercent"] || 0}

    full = Enum.filter(windows, fn {_type, _reset, used} -> used >= 100 end)

    case if(full == [],
           do: Enum.sort_by(windows, &elem(&1, 2), :desc),
           else: Enum.sort_by(full, &elem(&1, 1), :desc)
         ) do
      [{type, reset, _used} | _] -> {type, reset}
      [] -> {"five_hour", System.os_time(:second) + @fallback_wait_s}
    end
  end

  # -- turns ------------------------------------------------------------------------------------

  defp start_turn(text, state) do
    {id, state} = next_id(state)

    params =
      %{"threadId" => state.thread, "input" => [%{"type" => "text", "text" => text}]}
      |> put_unless_nil("effort", state.effort)
      |> put_unless_nil("model", state.model)

    {request(id, "turn/start", params),
     %{
       state
       | busy: true,
         messages: state.messages + 1,
         requests: Map.put(state.requests, id, :turn)
     }}
  end

  defp next_queued(%{queue: []} = state), do: {[], state}

  defp next_queued(%{queue: [text | rest]} = state), do: start_turn(text, %{state | queue: rest})

  defp finish_turn(subtype, error?, detail, state) do
    finished =
      event("finished", %{
        subtype: subtype,
        is_error: error?,
        num_turns: 1,
        duration_ms: nil,
        total_cost_usd: nil,
        claude_usage: nil,
        result: detail,
        session_id: state.thread,
        raw: %{}
      })

    {bytes, state} = next_queued(%{state | busy: false, turn: nil})
    {[finished], bytes, state}
  end

  defp failed(reason, state) do
    {[
       event("finished", %{
         subtype: "error_during_execution",
         is_error: true,
         num_turns: 0,
         duration_ms: nil,
         total_cost_usd: nil,
         claude_usage: nil,
         result: reason,
         session_id: state.thread,
         raw: %{}
       })
     ], [], state}
  end

  # -- items -----------------------------------------------------------------------------------

  defp item_started(%{"type" => "commandExecution"} = item),
    do: [tool_use(item["id"], "Bash", %{"command" => item["command"]})]

  defp item_started(%{"type" => "fileChange"} = item),
    do: [tool_use(item["id"], "Edit", %{"changes" => List.wrap(item["changes"])})]

  defp item_started(%{"type" => "mcpToolCall"} = item),
    do: [tool_use(item["id"], "#{item["server"]}:#{item["tool"]}", item["arguments"] || %{})]

  defp item_started(_other), do: []

  defp item_completed(%{"type" => "agentMessage", "text" => text}) when is_binary(text),
    do: [event("text", %{text: text, parent_tool_use_id: nil})]

  defp item_completed(%{"type" => "commandExecution"} = item) do
    output = to_string(item["aggregatedOutput"] || "")
    [tool_result(item["id"], failed_item?(item["status"], item["exitCode"]), output)]
  end

  defp item_completed(%{"type" => "fileChange"} = item),
    do: [tool_result(item["id"], failed_item?(item["status"], nil), "")]

  defp item_completed(%{"type" => "mcpToolCall"} = item),
    do: [
      tool_result(item["id"], failed_item?(item["status"], nil), inspect_result(item["result"]))
    ]

  defp item_completed(_other), do: []

  defp failed_item?(status, exit_code),
    do: status == "failed" or (is_integer(exit_code) and exit_code != 0)

  defp inspect_result(nil), do: ""
  defp inspect_result(result), do: Jason.encode!(result)

  defp tool_use(id, name, input),
    do: event("tool_use", %{id: id, name: name, input: input, parent_tool_use_id: nil})

  defp tool_result(id, error?, content) do
    event("tool_result", %{
      tool_use_id: id,
      is_error: error?,
      bytes: byte_size(content),
      excerpt: String.slice(content, 0, 2_000),
      parent_tool_use_id: nil
    })
  end

  # -- the stateless callbacks the behaviour requires ------------------------------------------

  # Never called: `ForgeWorker.Harness.stateful?/1` is true of this module, so a runner uses the
  # callbacks above. They answer rather than raise because a behaviour asks for them.
  @impl true
  def encode_message(text) when is_binary(text), do: [Jason.encode!(%{"text" => text}), "\n"]

  @impl true
  def encode_interrupt(request_id) when is_binary(request_id), do: []

  @impl true
  def parse_line(_line), do: []

  # -- wire helpers ----------------------------------------------------------------------------

  defp request(id, method, params),
    do: [Jason.encode!(%{"id" => id, "method" => method, "params" => params}), "\n"]

  defp notify(method, params),
    do: [Jason.encode!(%{"method" => method, "params" => params}), "\n"]

  defp next_id(%{next_id: id} = state), do: {id, %{state | next_id: id + 1}}

  defp event(type, payload), do: %{type: type, payload: payload}

  defp whole(n) when is_integer(n) and n >= 0, do: n
  defp whole(_), do: 0

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
