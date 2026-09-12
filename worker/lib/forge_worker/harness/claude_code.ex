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
    do: %{resume: true, permission_prompting: false, budget_turns: true, budget_usd: true}

  @impl true
  def command(%Spec{} = spec, job_dir, opts) do
    executable = Keyword.get(opts, :executable, "claude")

    args =
      [
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--max-turns",
        Integer.to_string(spec.budget.turns),
        "--max-budget-usd",
        format_cost(spec.budget.cost),
        "--permission-mode",
        "bypassPermissions"
      ] ++ model_args(opts) ++ resume_args(opts)

    credential = resolve(Keyword.get(opts, :credential))
    {executable, args, [{"FORGE_JOB", job_dir} | credential_env(credential)]}
  end

  defp model_args(opts) do
    case Keyword.get(opts, :model) do
      nil -> []
      model -> ["--model", model]
    end
  end

  defp resume_args(opts) do
    case Keyword.get(opts, :resume_session) do
      nil -> []
      session_id -> ["--resume", session_id]
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

  defp event(type, payload), do: %{type: type, payload: payload}
end
