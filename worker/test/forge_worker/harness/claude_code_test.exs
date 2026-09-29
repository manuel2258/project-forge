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

    # `docs/design/claude-code-events.md` § Resume: a fork starts from the session under an id of
    # its own. Only with a session to fork: the flag means nothing without `--resume`.
    test "forks a resumed session when asked, and only then" do
      {_exe, args, _env} =
        ClaudeCode.command(spec(), "/jobs/j", resume_session: "sess-1", fork_session: true)

      assert Enum.take(args, -3) == ["--resume", "sess-1", "--fork-session"]

      {_exe, args, _env} =
        ClaudeCode.command(spec(), "/jobs/j", resume_session: "sess-1", fork_session: false)

      refute "--fork-session" in args

      {_exe, args, _env} = ClaudeCode.command(spec(), "/jobs/j", fork_session: true)
      refute "--fork-session" in args
      refute "--resume" in args
    end

    # A conversation has no turn ceiling — it ends when a person stops talking — and no state to
    # take a cost ceiling from, so the caller passes what is left of the day instead.
    test "streaming mode takes messages on stdin and drops the turn ceiling" do
      {_exe, args, _env} =
        ClaudeCode.command(spec(), "/jobs/j", mode: :streaming, max_cost: 1.5)

      assert args ==
               ~w(-p --output-format stream-json --verbose --input-format stream-json
                  --replay-user-messages --max-budget-usd 1.50
                  --permission-mode bypassPermissions)

      refute "--max-turns" in args
    end

    test "a streaming invocation with nothing left of the day still has to say so" do
      {_exe, args, _env} = ClaudeCode.command(spec(), "/jobs/j", mode: :streaming)

      # No ceiling passed means no flag, not an unbounded one asserted as bounded. The caller
      # deciding there is nothing left is what refuses the turn; see § Spend.
      refute "--max-budget-usd" in args
    end
  end

  describe "writing to a running harness" do
    test "a message is one JSON line in the shape the harness reads" do
      assert %{"type" => "user", "message" => %{"role" => "user", "content" => content}} =
               ClaudeCode.encode_message("hello") |> IO.iodata_to_binary() |> Jason.decode!()

      assert content == [%{"type" => "text", "text" => "hello"}]

      assert ClaudeCode.encode_message("hello")
             |> IO.iodata_to_binary()
             |> String.ends_with?("\n")
    end

    test "an interrupt carries the id its acknowledgement comes back with" do
      assert %{"type" => "control_request", "request_id" => "forge-2", "request" => request} =
               ClaudeCode.encode_interrupt("forge-2") |> IO.iodata_to_binary() |> Jason.decode!()

      assert request == %{"subtype" => "interrupt"}
    end

    # Under --replay-user-messages the harness echoes a message when it takes it, which for one
    # sent mid-turn is after the current turn's result. That echo is the only evidence of
    # delivery there is, and it used to parse to nothing at all.
    test "the echo of a user message is delivery, not a tool result" do
      assert [%{type: "delivered", payload: %{text: "a question"}}] =
               ClaudeCode.parse_line(
                 ~s({"type":"user","message":{"role":"user","content":[{"type":"text","text":"a question"}]}})
               )
    end

    test "an interrupt is acknowledged with the id that asked" do
      assert [%{type: "control", payload: payload}] =
               ClaudeCode.parse_line(
                 ~s({"type":"control_response","response":{"subtype":"success","request_id":"forge-2","response":{"still_queued":[]}}})
               )

      assert payload.request_id == "forge-2"
      assert payload.subtype == "success"
    end
  end

  describe "parse_line/1" do
    test "maps every documented message type" do
      assert [%{type: "started", payload: %{session_id: "s", model: "m", tools: ["Read"]}}] =
               ClaudeCode.parse_line(
                 ~s({"type":"system","subtype":"init","session_id":"s","model":"m","tools":["Read"]})
               )

      # The version that will write the session file, recorded beside it for a later resume.
      assert [%{type: "started", payload: %{version: "2.1.284"}}] =
               ClaudeCode.parse_line(
                 ~s({"type":"system","subtype":"init","session_id":"s","claude_code_version":"2.1.284"})
               )

      assert [%{type: "retry", payload: %{attempt: 2, error: "rate_limit"}}] =
               ClaudeCode.parse_line(
                 ~s({"type":"system","subtype":"api_retry","attempt":2,"max_retries":5,"error":"rate_limit"})
               )

      assert [%{type: "notice", payload: %{subtype: "plugin_install"}}] =
               ClaudeCode.parse_line(~s({"type":"system","subtype":"plugin_install"}))

      # The sample `docs/design/capacity.md` § What the provider reports records from the dev
      # node. It used to fall through to `unknown`, and the platform's pick needs it by name.
      line =
        ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1789210800,"rateLimitType":"five_hour","utilization":0.96,"isUsingOverage":false,"surpassedThreshold":0.9},"session_id":"s"})

      assert [%{type: "rate_limit", payload: payload}] = ClaudeCode.parse_line(line)

      assert %{
               status: "allowed_warning",
               resets_at: 1_789_210_800,
               rate_limit_type: "five_hour",
               utilization: 0.96,
               is_using_overage: false
             } = payload

      assert payload.raw["session_id"] == "s"
      assert payload.windows == nil

      # `unifiedWindows`, in the shape a third-party report shows newer releases sending: every
      # window's figure on every event. A window that is not an object is no window.
      line =
        ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1790184000,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.53,"resetsAt":1790184000},"seven_day":{"utilization":0.15,"resetsAt":1790222400},"odd":7}}})

      assert [%{type: "rate_limit", payload: %{windows: windows}}] = ClaudeCode.parse_line(line)

      assert windows == %{
               "five_hour" => %{utilization: 0.53, resets_at: 1_790_184_000},
               "seven_day" => %{utilization: 0.15, resets_at: 1_790_222_400}
             }

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

  describe "probe/1" do
    # **A harness, not an account.** The probe used to ask the API which models the machine's
    # token could use and whether it logged in; a machine holds no token now, and both questions
    # are the platform's, asked once per credential when it is saved (`docs/design/credentials.md`
    # § Checked on save). What is left makes no request and so cannot fail on the network.
    test "reports the harness, its version and its aliases, and nothing about an account" do
      offer = ClaudeCode.probe(executable: fake_executable(), credential: {:oauth, "tok"})

      assert offer == %{
               driver: "claude_code",
               name: "Claude Code",
               version: "9.9.9",
               aliases: ~w(opus sonnet haiku fable)
             }
    end

    # A worker that cannot describe itself is still a worker that can run work, so this answers
    # rather than raising.
    test "a missing binary still answers" do
      offer = ClaudeCode.probe(executable: "/nonexistent/claude")

      assert offer.version == nil
      assert offer.driver == "claude_code"
      assert offer.aliases == ~w(opus sonnet haiku fable)
    end

    test "names its driver on its own, for when the probe cannot" do
      assert ClaudeCode.driver() == "claude_code"
    end
  end

  test "declares its capabilities" do
    assert ClaudeCode.capabilities() == %{
             resume: true,
             permission_prompting: false,
             budget_turns: true,
             budget_usd: true,
             # Measured, not assumed: `measure/lib/streaming.sh` drives the real harness and
             # asserts it. A runner asked for a conversation refuses a driver without this
             # rather than starting one that can never be spoken to.
             streaming_input: true
           }
  end
end
