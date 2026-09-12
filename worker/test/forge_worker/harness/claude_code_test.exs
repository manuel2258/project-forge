defmodule ForgeWorker.Harness.ClaudeCodeTest do
  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures

  alias ForgeWorker.Harness.ClaudeCode

  describe "command/3" do
    test "builds the documented headless invocation with budgets from the spec" do
      {exe, args, env} =
        ClaudeCode.command(spec(), "/jobs/j",
          executable: "/bin/claude",
          credential: {:api_key, "k"}
        )

      assert exe == "/bin/claude"

      assert args ==
               ~w(-p --output-format stream-json --verbose --max-turns 40 --max-budget-usd 2.00 --permission-mode bypassPermissions)

      assert env == [
               {"FORGE_JOB", "/jobs/j"},
               {"ANTHROPIC_API_KEY", {:secret, "k"}},
               {"CLAUDE_CODE_OAUTH_TOKEN", false}
             ]
    end

    test "adds model and resume flags when asked, and sets exactly one credential" do
      {_exe, args, env} =
        ClaudeCode.command(spec(), "/jobs/j",
          model: "opus",
          resume_session: "sess-1",
          credential: {:oauth, "t"}
        )

      assert Enum.take(args, -4) == ["--model", "opus", "--resume", "sess-1"]
      assert {"CLAUDE_CODE_OAUTH_TOKEN", {:secret, "t"}} in env
      assert {"ANTHROPIC_API_KEY", false} in env

      {_exe, _args, env} = ClaudeCode.command(spec(), "/jobs/j", [])
      assert {"ANTHROPIC_API_KEY", false} in env
      assert {"CLAUDE_CODE_OAUTH_TOKEN", false} in env
    end
  end

  describe "parse_line/1" do
    test "maps every documented message type" do
      assert [%{type: "started", payload: %{session_id: "s", model: "m", tools: ["Read"]}}] =
               ClaudeCode.parse_line(
                 ~s({"type":"system","subtype":"init","session_id":"s","model":"m","tools":["Read"]})
               )

      assert [%{type: "retry", payload: %{attempt: 2, error: "rate_limit"}}] =
               ClaudeCode.parse_line(
                 ~s({"type":"system","subtype":"api_retry","attempt":2,"max_retries":5,"error":"rate_limit"})
               )

      assert [%{type: "notice", payload: %{subtype: "plugin_install"}}] =
               ClaudeCode.parse_line(~s({"type":"system","subtype":"plugin_install"}))

      assert [
               %{type: "text", payload: %{text: "hi"}},
               %{type: "tool_use", payload: %{id: "t1", name: "Read", input: %{"path" => "x"}}}
             ] =
               ClaudeCode.parse_line(
                 ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hi"},{"type":"thinking","thinking":"..."},{"type":"tool_use","id":"t1","name":"Read","input":{"path":"x"}}]}})
               )

      assert [
               %{
                 type: "tool_result",
                 payload: %{tool_use_id: "t1", is_error: false, bytes: 5, excerpt: "hello"}
               }
             ] =
               ClaudeCode.parse_line(
                 ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"hello"}]}]}})
               )

      assert [] = ClaudeCode.parse_line(~s({"type":"stream_event","event":{}}))

      assert [
               %{
                 type: "finished",
                 payload: %{
                   subtype: "success",
                   is_error: false,
                   num_turns: 3,
                   total_cost_usd: 0.04,
                   session_id: "s"
                 }
               }
             ] =
               ClaudeCode.parse_line(
                 ~s({"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":0.04,"session_id":"s"})
               )
    end

    test "excerpts are cut on character boundaries" do
      long = String.duplicate("é", 3000)

      line =
        Jason.encode!(%{
          type: "user",
          message: %{content: [%{type: "tool_result", tool_use_id: "t", content: long}]}
        })

      assert [%{payload: %{excerpt: excerpt, bytes: 6000}}] = ClaudeCode.parse_line(line)
      assert String.valid?(excerpt)
      assert byte_size(excerpt) in 4094..4096
    end

    test "never drops or raises on unexpected input" do
      assert [%{type: "unknown", payload: %{type: "novel", raw: %{"type" => "novel"}}}] =
               ClaudeCode.parse_line(~s({"type":"novel"}))

      assert [%{type: "malformed", payload: %{reason: "not JSON", raw: "nope"}}] =
               ClaudeCode.parse_line("nope")

      assert [%{type: "malformed", payload: %{reason: "no type field"}}] =
               ClaudeCode.parse_line(~s({"a":1}))

      assert [] = ClaudeCode.parse_line(~s({"type":"assistant","message":{}}))
    end

    test "keeps subagent attribution" do
      assert [%{payload: %{parent_tool_use_id: "agent-1"}}] =
               ClaudeCode.parse_line(
                 ~s({"type":"assistant","parent_tool_use_id":"agent-1","message":{"content":[{"type":"text","text":"sub"}]}})
               )
    end
  end

  test "declares its capabilities" do
    assert ClaudeCode.capabilities() == %{
             resume: true,
             permission_prompting: false,
             budget_turns: true,
             budget_usd: true
           }
  end
end
