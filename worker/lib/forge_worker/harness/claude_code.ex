defmodule ForgeWorker.Harness.ClaudeCode do
  @moduledoc """
  Driver for Claude Code run headless. Implements `docs/design/claude-code-events.md`:
  the invocation, and the mapping of documented stream-json message types to events.
  Unknown and malformed lines become events too; nothing is dropped and nothing raises.
  """

  @behaviour ForgeWorker.Harness

  alias ForgeCore.Job.Spec

  @excerpt_bytes 4096

  @impl true
  def capabilities,
    do: %{
      resume: true,
      permission_prompting: false,
      budget_turns: true,
      budget_usd: true,
      streaming_input: true
    }

  @impl true
  def command(%Spec{} = spec, job_dir, opts) do
    executable = Keyword.get(opts, :executable, "claude")

    args =
      ["-p", "--output-format", "stream-json", "--verbose"] ++
        mode_args(spec, opts) ++
        ["--permission-mode", "bypassPermissions"] ++
        model_args(opts) ++ effort_args(opts) ++ resume_args(opts)

    credential = resolve(Keyword.get(opts, :credential))
    {executable, args, [{"FORGE_JOB", job_dir} | credential_env(credential)]}
  end

  # A conversation has no turn ceiling — it ends when a person stops talking — and its cost
  # ceiling is the day's remaining allowance rather than a state's budget, because a chat has no
  # state. `--replay-user-messages` is what makes delivery observable: the harness echoes a
  # message when it takes it, which for a message sent mid-turn is after the current turn ends.
  defp mode_args(%Spec{} = spec, opts) do
    case Keyword.get(opts, :mode, :prompt) do
      :streaming ->
        ["--input-format", "stream-json", "--replay-user-messages"] ++ max_cost_args(opts)

      :prompt ->
        ["--max-turns", Integer.to_string(spec.budget.turns)] ++
          ["--max-budget-usd", format_cost(Keyword.get(opts, :max_cost) || spec.budget.cost)]
    end
  end

  defp max_cost_args(opts) do
    case Keyword.get(opts, :max_cost) do
      nil -> []
      cost -> ["--max-budget-usd", format_cost(cost)]
    end
  end

  defp model_args(opts), do: flag_args(opts, :model, "--model")

  # Passed through unexamined: `--effort` takes `low`, `medium`, `high`, `xhigh` or `max`, and
  # which of them are current is the CLI's business rather than this driver's
  # (`docs/design/workflow-grammar-v1.md` § Effort). A level it does not know fails the run with
  # its own message. Nothing resolved is no flag at all, leaving the harness its own default.
  defp effort_args(opts), do: flag_args(opts, :effort, "--effort")

  # Nil and the empty string are both "nobody resolved one", and the empty string is the one that
  # has to be said: a node's `FORGE_CLAUDE_EFFORT` can be present and empty, and this is the last
  # place that can refuse it before it becomes `--effort ''` on a command line and fails the run.
  # Unexamined otherwise — the value is one argv slot and never a shell word, so a level the
  # harness rejects fails in the harness's own words.
  defp flag_args(opts, key, flag) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> [flag, value]
      _unset_or_empty -> []
    end
  end

  # A fork begins with the session's conversation under a new id, leaving the old one as it was:
  # a new attempt resuming its predecessor's, or a reopened conversation, whose turns are
  # numbered from one again (`docs/design/claude-code-events.md` § Resume).
  defp resume_args(opts) do
    case {Keyword.get(opts, :resume_session), Keyword.get(opts, :fork_session, false)} do
      {nil, _fork} -> []
      {session_id, true} -> ["--resume", session_id, "--fork-session"]
      {session_id, false} -> ["--resume", session_id]
    end
  end

  # Exactly one credential reaches the process, as a secret the runner forwards through the
  # environment only; the other variable is explicitly absent.
  defp credential_env({:api_key, value}),
    do: [{"ANTHROPIC_API_KEY", {:secret, value}}, {"CLAUDE_CODE_OAUTH_TOKEN", false}]

  defp credential_env({:oauth, value}),
    do: [{"CLAUDE_CODE_OAUTH_TOKEN", {:secret, value}}, {"ANTHROPIC_API_KEY", false}]

  defp credential_env(nil), do: [{"ANTHROPIC_API_KEY", false}, {"CLAUDE_CODE_OAUTH_TOKEN", false}]

  defp resolve(fun) when is_function(fun, 0), do: fun.()
  defp resolve(credential), do: credential

  # -- the probe ------------------------------------------------------------------------------

  @probe_timeout_ms 10_000

  # Documented in `claude --help` as the aliases `--model` takes, and nowhere machine-readable.
  # Declared rather than discovered: the driver knowing its own CLI's four shorthands is a
  # different kind of claim from a model list, which is an account's and is asked of the provider
  # by the platform when a credential is saved (`docs/design/credentials.md` § Checked on save).
  @aliases ~w(opus sonnet haiku fable)

  @impl true
  def driver, do: "claude_code"

  # **No request, and so nothing that fails on a network blip.** The probe used to ask
  # `GET /v1/models` with the machine's own token to learn the models and whether the login
  # worked; a machine holds no token now, and both questions moved to where the tokens are. Its
  # version is also what a carried session is checked against before it is put back
  # (`ForgeWorker.Job.Session`).
  @impl true
  def probe(opts) do
    %{
      driver: driver(),
      name: "Claude Code",
      version: version(Keyword.get(opts, :executable, "claude")),
      aliases: @aliases
    }
  end

  # `claude --version` prints "2.1.220 (Claude Code)". Only the version is kept; the name is
  # this module's to say. A binary that is missing or will not run is `nil`, not a crash — the
  # probe's contract is that it always answers.
  defp version(executable) do
    # The rescue is inside the task and not around it: `Task.async` links, so a binary that is
    # not there raises in the task and takes the caller with it however well the caller guards.
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
      {:ok, {output, 0}} -> output |> String.split(" ", parts: 2) |> hd() |> String.trim()
      _other -> nil
    end
  end

  @impl true
  def encode_message(text) when is_binary(text) do
    [
      Jason.encode!(%{
        "type" => "user",
        "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
      }),
      "\n"
    ]
  end

  @impl true
  def encode_interrupt(request_id) when is_binary(request_id) do
    [
      Jason.encode!(%{
        "type" => "control_request",
        "request_id" => request_id,
        "request" => %{"subtype" => "interrupt"}
      }),
      "\n"
    ]
  end

  defp format_cost(cost) when is_integer(cost), do: Integer.to_string(cost)
  defp format_cost(cost) when is_float(cost), do: :erlang.float_to_binary(cost, decimals: 2)

  @impl true
  def parse_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => _} = message} -> normalise(message)
      {:ok, _other} -> [event("malformed", %{raw: line, reason: "no type field"})]
      {:error, _} -> [event("malformed", %{raw: line, reason: "not JSON"})]
    end
  end

  defp normalise(%{"type" => "system", "subtype" => "init"} = m) do
    [
      event("started", %{
        session_id: m["session_id"],
        model: m["model"],
        # What wrote the session file this run leaves, recorded beside it so a later resume is
        # restored only onto the same CLI (`docs/design/claude-code-events.md` § Resume).
        version: m["claude_code_version"],
        tools: m["tools"] || [],
        raw: m
      })
    ]
  end

  defp normalise(%{"type" => "system", "subtype" => "api_retry"} = m) do
    [
      event("retry", %{
        attempt: m["attempt"],
        max_retries: m["max_retries"],
        error: m["error"],
        raw: m
      })
    ]
  end

  defp normalise(%{"type" => "system"} = m),
    do: [event("notice", %{subtype: m["subtype"], raw: m})]

  # Undocumented, emitted in practice, and the provider's own report of the account's window
  # (`docs/design/capacity.md` § What the provider reports). `claude-code-events.md` listed this
  # mapping while the message was still falling through to `unknown` below; the platform's pick
  # reads it now to pass over a limited credential (`docs/design/credentials.md` § Rate limits are
  # per credential). `utilization` arrives only once the warning threshold is crossed, and is `nil`
  # rather than zero until then.
  #
  # `windows` is `unifiedWindows`, which third-party reports show newer releases adding: every
  # window's utilization and reset on every event. Nothing recorded here has it, so it is mapped
  # when present and `nil` otherwise, and nothing decides on it — it carries no status.
  defp normalise(%{"type" => "rate_limit_event", "rate_limit_info" => %{} = info} = m) do
    [
      event("rate_limit", %{
        status: info["status"],
        resets_at: info["resetsAt"],
        rate_limit_type: info["rateLimitType"],
        utilization: info["utilization"],
        is_using_overage: info["isUsingOverage"],
        windows: windows(info["unifiedWindows"]),
        raw: m
      })
    ]
  end

  defp normalise(%{"type" => "assistant"} = m) do
    parent = m["parent_tool_use_id"]

    m
    |> content_blocks()
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} ->
        [event("text", %{text: text, parent_tool_use_id: parent})]

      %{"type" => "tool_use"} = block ->
        [
          event("tool_use", %{
            id: block["id"],
            name: block["name"],
            input: block["input"],
            parent_tool_use_id: parent
          })
        ]

      _other ->
        []
    end)
  end

  defp normalise(%{"type" => "user"} = m) do
    parent = m["parent_tool_use_id"]

    m
    |> content_blocks()
    |> Enum.flat_map(fn
      # Under `--replay-user-messages` the harness echoes a message when it *takes* it, which
      # for one sent mid-turn is after the current turn's result. That is what makes delivery
      # observable rather than something the worker has to assert — § Turns. In prompt mode no
      # such line is ever written, so this clause is only reached by a conversation.
      %{"type" => "text", "text" => text} ->
        [event("delivered", %{text: text, parent_tool_use_id: parent})]

      %{"type" => "tool_result"} = block ->
        content = tool_result_content(block["content"])

        [
          event("tool_result", %{
            tool_use_id: block["tool_use_id"],
            is_error: block["is_error"] == true,
            bytes: byte_size(content),
            excerpt: excerpt(content),
            parent_tool_use_id: parent
          })
        ]

      _other ->
        []
    end)
  end

  defp normalise(%{"type" => "stream_event"}), do: []

  # The acknowledgement of an interrupt. `request_id` correlates it with the request that asked,
  # which is the only way to tell an interrupt that landed from one that arrived after the turn
  # had already ended.
  defp normalise(%{"type" => "control_response"} = m) do
    response = m["response"] || %{}

    [
      event("control", %{
        request_id: response["request_id"],
        subtype: response["subtype"],
        raw: m
      })
    ]
  end

  defp normalise(%{"type" => "result"} = m) do
    [
      event("finished", %{
        subtype: m["subtype"],
        is_error: m["is_error"] == true,
        num_turns: m["num_turns"],
        duration_ms: m["duration_ms"],
        total_cost_usd: m["total_cost_usd"],
        usage: m["usage"],
        result: m["result"],
        session_id: m["session_id"],
        raw: m
      })
    ]
  end

  defp normalise(m), do: [event("unknown", %{type: m["type"], raw: m})]

  # Truncates on a character boundary so the excerpt stays valid UTF-8 for JSON.
  defp excerpt(content) when byte_size(content) <= @excerpt_bytes, do: content

  defp excerpt(content) do
    content
    |> String.graphemes()
    |> Enum.reduce_while({0, []}, fn g, {size, acc} ->
      if size + byte_size(g) > @excerpt_bytes,
        do: {:halt, {size, acc}},
        else: {:cont, {size + byte_size(g), [g | acc]}}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp content_blocks(%{"message" => %{"content" => blocks}}) when is_list(blocks), do: blocks

  defp content_blocks(%{"message" => %{"content" => text}}) when is_binary(text),
    do: [%{"type" => "text", "text" => text}]

  defp content_blocks(_), do: []

  defp tool_result_content(content) when is_binary(content), do: content

  defp tool_result_content(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{"type" => "text", "text" => text} -> text
      other -> Jason.encode!(other)
    end)
  end

  defp tool_result_content(nil), do: ""
  defp tool_result_content(other), do: Jason.encode!(other)

  defp windows(%{} = windows) do
    for {type, %{} = window} <- windows, into: %{} do
      {type, %{utilization: window["utilization"], resets_at: window["resetsAt"]}}
    end
  end

  defp windows(_absent), do: nil

  defp event(type, payload), do: %{type: type, payload: payload}
end
