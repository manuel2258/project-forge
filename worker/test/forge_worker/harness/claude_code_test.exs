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

  describe "probe/1" do
    # The models a credential may use cannot be got from the CLI — 2.1.220 has no models
    # subcommand and `--model` rejects a name only once a turn is under way — so the driver asks
    # the API, which is also what makes this free. See docs/design/worker-channel.md § What a
    # worker offers.
    test "reports the models the credential may use, and the harness running them" do
      offer =
        ClaudeCode.probe(
          executable: fake_executable(),
          credential: {:oauth, "tok"},
          req_options: [plug: &models_plug(&1, self())]
        )

      assert offer.driver == "claude_code"
      assert offer.version == "9.9.9"
      assert offer.login == :ok

      assert offer.models == [
               %{id: "claude-opus-5", name: "Claude Opus 5"},
               # A model the API named without a display name is still offerable; its id stands
               # in, because a missing label is not a missing model.
               %{id: "claude-haiku-4-5-20251001", name: "claude-haiku-4-5-20251001"}
             ]

      assert_received {:probed, conn}
      assert {"authorization", "Bearer tok"} in conn.req_headers
      assert {"anthropic-beta", "oauth-2025-04-20"} in conn.req_headers
    end

    # The request itself, none of which was asserted anywhere: the test plug answers whatever
    # it is asked, so a probe pointed at the wrong host or the wrong path went on reporting
    # models. `anthropic-version` is not optional decoration — the real API refuses a request
    # without it, which would make every worker in the fleet report `login: unknown` while this
    # suite stayed green, and § What a worker offers is the note that says the login check is
    # the point. `limit=100` is what makes one request enough to list an account's models.
    test "the probe asks the documented endpoint, with the version header the API requires" do
      ClaudeCode.probe(
        executable: fake_executable(),
        credential: {:oauth, "tok"},
        req_options: [plug: &models_plug(&1, self())]
      )

      assert_received {:probed, conn}
      assert conn.method == "GET"
      assert conn.host == "api.anthropic.com"
      assert conn.request_path == "/v1/models"
      assert conn.query_string == "limit=100"
      assert {"anthropic-version", "2023-06-01"} in conn.req_headers
    end

    # A subscription token is a bearer token and an API key is an `x-api-key`; sending either as
    # the other is a 401, which is the whole reason the two are not one clause.
    test "an api key authenticates as an api key" do
      ClaudeCode.probe(
        executable: fake_executable(),
        credential: {:api_key, "sk-1"},
        req_options: [plug: &models_plug(&1, self())]
      )

      assert_received {:probed, conn}
      assert {"x-api-key", "sk-1"} in conn.req_headers
      refute Enum.any?(conn.req_headers, fn {name, _value} -> name == "authorization" end)
    end

    # The point of the probe: a machine minted without a working credential is visibly not
    # logged in at `ready`, rather than silently failing every job it is given.
    #
    # Both statuses, because the API uses both and they mean the same thing here: 401 for a
    # credential it does not recognise, 403 for one it recognises and will not serve — a
    # revoked subscription token, a key whose account is disabled. A driver that knew only
    # about 401 would report the second as `:unknown`, which reads as a network blip and sends
    # an operator looking for a problem the machine does not have.
    for status <- [401, 403] do
      test "a credential refused with #{status} is a bad login, not no models" do
        offer =
          ClaudeCode.probe(
            executable: fake_executable(),
            credential: {:oauth, "stale"},
            req_options: [plug: &Plug.Conn.send_resp(&1, unquote(status), ~s({"error":"nope"}))]
          )

        assert offer.login == :invalid
        assert offer.models == []
      end
    end

    # Never `:invalid`: an unreachable API says nothing about the credential, and a worker that
    # reported one as the other would send an operator looking for a login problem it does not
    # have.
    test "an unreachable api is unknown rather than refused" do
      offer =
        ClaudeCode.probe(
          executable: fake_executable(),
          credential: {:oauth, "tok"},
          req_options: [plug: &Req.Test.transport_error(&1, :econnrefused)]
        )

      assert offer.login == :unknown
      assert offer.models == []
    end

    # A worker that cannot describe itself is still a worker that can run work, so every one of
    # these answers rather than raising.
    test "no credential and a missing binary still answer" do
      offer = ClaudeCode.probe(executable: "/nonexistent/claude")

      assert offer.version == nil
      assert offer.login == :unknown
      assert offer.models == []
      assert offer.aliases == ~w(opus sonnet haiku fable)
    end
  end

  defp models_plug(conn, test) do
    send(test, {:probed, conn})

    Req.Test.json(conn, %{
      "data" => [
        %{"id" => "claude-opus-5", "display_name" => "Claude Opus 5"},
        %{"id" => "claude-haiku-4-5-20251001"},
        %{"display_name" => "a row with no id at all"}
      ]
    })
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
