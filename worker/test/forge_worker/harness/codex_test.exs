defmodule ForgeWorker.Harness.CodexTest do
  @moduledoc """
  The Codex driver's conversation with the app-server, scripted.

  **The messages are written from OpenAI's description of the app-server, not captured from an
  installed `codex`** (`docs/design/codex.md` § Not verified here): these tests hold the driver to
  its own reading and to forge's rules about it — usage is fresh input less what the cache read,
  a call is counted once, a message waits for the turn in flight — and say nothing about whether
  the reading is right.
  """

  use ExUnit.Case, async: true

  alias ForgeWorker.Harness
  alias ForgeWorker.Harness.Codex
  alias ForgeWorker.Job.Meter

  defp decode(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp feed(state, messages) do
    Enum.reduce(messages, {[], [], state}, fn message, {events, bytes, state} ->
      {more_events, more_bytes, state} = Codex.handle_line(Jason.encode!(message), state)
      {events ++ more_events, bytes ++ decode(more_bytes), state}
    end)
  end

  # A conversation brought to where a turn can be started: initialised, thread made.
  defp ready(opts \\ []) do
    {first, state} = Codex.init(opts)
    assert [%{"id" => 0, "method" => "initialize"}] = decode(first)

    {_events, bytes, state} = feed(state, [%{"id" => 0, "result" => %{}}])
    assert [%{"method" => "initialized"}, %{"id" => id, "method" => method}] = bytes
    {id, method, state}
  end

  test "it is a stateful driver, which Claude Code is not" do
    assert Harness.stateful?(Codex)
    refute Harness.stateful?(ForgeWorker.Harness.ClaudeCode)
  end

  describe "starting" do
    test "initialize, then a thread, then the turn the first message waits for" do
      {id, "thread/start", state} = ready(model: "gpt-x")

      # Sent before the thread exists: held, nothing written yet.
      assert {[], state} = Codex.send_message("do the thing", state)

      {events, bytes, state} =
        feed(state, [%{"id" => id, "result" => %{"thread" => %{"id" => "th-1"}}}])

      assert [%{type: "started", payload: %{session_id: "th-1"}}] = events

      assert [%{"method" => "turn/start", "params" => params}] = bytes
      assert params["threadId"] == "th-1"
      assert params["input"] == [%{"type" => "text", "text" => "do the thing"}]
      assert state.busy
    end

    test "a thread to resume is resumed, not started" do
      {id, "thread/resume", state} = ready(resume_session: "th-old")

      {_e, _b, state} =
        feed(state, [%{"id" => id, "result" => %{"thread" => %{"id" => "th-old"}}}])

      assert state.thread == "th-old"
    end

    test "approvals are off and the sandbox is the job's slice" do
      {first, state} = Codex.init([])
      {_e, bytes, _state} = feed(elem({first, state}, 1), [%{"id" => 0, "result" => %{}}])

      assert [_, %{"params" => %{"approvalPolicy" => "never", "sandbox" => "danger-full-access"}}] =
               bytes
    end

    test "a refused initialize ends the run with a result that says so" do
      {_first, state} = Codex.init([])
      {events, _b, _s} = feed(state, [%{"id" => 0, "error" => %{"message" => "no"}}])

      assert [%{type: "finished", payload: %{is_error: true, result: "initialize was refused"}}] =
               events
    end
  end

  describe "a turn" do
    setup do
      {id, _method, state} = ready()
      {[], state} = Codex.send_message("first", state)
      {_e, _b, state} = feed(state, [%{"id" => id, "result" => %{"thread" => %{"id" => "th-1"}}}])
      %{state: state}
    end

    test "agent messages and tool calls become the schema's events", %{state: state} do
      {events, [], _state} =
        feed(state, [
          %{"method" => "turn/started", "params" => %{"turn" => %{"id" => "t-1"}}},
          %{
            "method" => "item/started",
            "params" => %{
              "item" => %{"type" => "commandExecution", "id" => "i1", "command" => "ls"}
            }
          },
          %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{
                "type" => "commandExecution",
                "id" => "i1",
                "aggregatedOutput" => "a\n",
                "exitCode" => 2,
                "status" => "completed"
              }
            }
          },
          %{
            "method" => "item/completed",
            "params" => %{"item" => %{"type" => "agentMessage", "id" => "i2", "text" => "done"}}
          }
        ])

      assert [
               %{
                 type: "tool_use",
                 payload: %{id: "i1", name: "Bash", input: %{"command" => "ls"}}
               },
               %{
                 type: "tool_result",
                 payload: %{tool_use_id: "i1", is_error: true, excerpt: "a\n"}
               },
               %{type: "text", payload: %{text: "done"}}
             ] = events
    end

    test "usage is the last call's: fresh input is what the cache did not read", %{state: state} do
      usage = fn total, input, cached, output ->
        %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{
            "tokenUsage" => %{
              "total" => %{"totalTokens" => total},
              "last" => %{
                "inputTokens" => input,
                "cachedInputTokens" => cached,
                "outputTokens" => output
              }
            }
          }
        }
      end

      {events, [], _} = feed(state, [usage.(1_500, 1_000, 800, 500)])

      assert [%{type: "usage", payload: %{tokens: tokens}}] = events
      assert tokens == %{input: 200, cache_write: 0, cache_read: 800, output: 500}
    end

    test "a notification repeated with nothing new is the same call, counted once", %{
      state: state
    } do
      note = %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{"totalTokens" => 900},
            "last" => %{"inputTokens" => 700, "cachedInputTokens" => 100, "outputTokens" => 200}
          }
        }
      }

      {events, [], _} = feed(state, [note, note, note])
      assert length(events) == 1

      meter = Enum.reduce(events, Meter.new(), &Meter.observe(&2, &1.payload))
      assert Meter.usage(meter) == 600 + 10 + 1000
    end

    test "cached tokens beyond the input are not taken off twice", %{state: state} do
      note = %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{"totalTokens" => 10},
            "last" => %{"inputTokens" => 5, "cachedInputTokens" => 9, "outputTokens" => 0}
          }
        }
      }

      assert {[%{payload: %{tokens: %{input: 0, cache_read: 5}}}], [], _} = feed(state, [note])
    end

    test "the account's two windows are the schema's five-hour and weekly", %{state: state} do
      {events, [], _} =
        feed(state, [
          %{
            "method" => "account/rateLimits/updated",
            "params" => %{
              "rateLimits" => %{
                "primary" => %{"usedPercent" => 42, "resetsAt" => 1_800_000_000},
                "secondary" => %{"usedPercent" => 100, "resetsAt" => 1_800_500_000}
              }
            }
          }
        ])

      assert [
               %{
                 type: "rate_limit",
                 payload: %{
                   rate_limit_type: "five_hour",
                   status: "allowed",
                   utilization: 0.42,
                   resets_at: 1_800_000_000
                 }
               },
               %{type: "rate_limit", payload: %{rate_limit_type: "seven_day", status: "rejected"}}
             ] = events
    end

    test "a message sent during a turn is held and goes when the turn completes", %{state: state} do
      {_e, _b, state} =
        feed(state, [%{"method" => "turn/started", "params" => %{"turn" => %{"id" => "t-1"}}}])

      assert {[], state} = Codex.send_message("second", state)

      {events, bytes, state} =
        feed(state, [
          %{
            "method" => "turn/completed",
            "params" => %{"turn" => %{"id" => "t-1", "status" => "completed"}}
          }
        ])

      assert [
               %{
                 type: "finished",
                 payload: %{subtype: "success", is_error: false, session_id: "th-1"}
               }
             ] = events

      assert [%{"method" => "turn/start", "params" => %{"input" => [%{"text" => "second"}]}}] =
               bytes

      assert state.busy
    end

    test "an idle conversation sends at once", %{state: state} do
      {_e, _b, state} =
        feed(state, [
          %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "completed"}}}
        ])

      assert {bytes, _} = Codex.send_message("next", state)
      assert [%{"method" => "turn/start"}] = decode(bytes)
    end

    test "an interrupt names the thread and the turn in flight", %{state: state} do
      {_e, _b, state} =
        feed(state, [%{"method" => "turn/started", "params" => %{"turn" => %{"id" => "t-9"}}}])

      assert {bytes, _} = Codex.interrupt("req-1", state)

      assert [
               %{
                 "id" => "req-1",
                 "method" => "turn/interrupt",
                 "params" => %{"threadId" => "th-1", "turnId" => "t-9"}
               }
             ] = decode(bytes)

      # Before any turn there is nothing to interrupt.
      assert {[], _} = Codex.interrupt("req-2", %{state | turn: nil})
    end

    test "a failed turn is an error result, and a usage limit is the rate limit Claude's reads as",
         %{state: state} do
      {events, [], _} =
        feed(state, [
          %{
            "method" => "turn/completed",
            "params" => %{
              "turn" => %{
                "status" => "failed",
                "error" => %{"message" => "You have hit your usage limit"}
              }
            }
          }
        ])

      assert [
               %{type: "rate_limit", payload: %{status: "rejected"}},
               %{type: "finished", payload: %{is_error: true, subtype: "error_during_execution"}}
             ] = events

      {other, [], _} =
        feed(state, [
          %{
            "method" => "turn/completed",
            "params" => %{
              "turn" => %{"status" => "failed", "error" => %{"message" => "the model fell over"}}
            }
          }
        ])

      assert [%{type: "finished", payload: %{is_error: true}}] = other
    end

    test "lines that are not messages are reported, never raised", %{state: state} do
      assert {[%{type: "malformed"}], [], _} = Codex.handle_line("not json", state)
      assert {[%{type: "malformed"}], [], _} = Codex.handle_line("[1]", state)
    end
  end

  describe "everything else the app-server says" do
    setup do
      {id, _method, state} = ready()
      {[], state} = Codex.send_message("first", state)
      {_e, _b, state} = feed(state, [%{"id" => id, "result" => %{"thread" => %{"id" => "th-1"}}}])
      %{state: state}
    end

    defp note(method, params), do: %{"method" => method, "params" => params}

    test "file changes and tool calls are tool uses and results", %{state: state} do
      {events, [], _} =
        feed(state, [
          note("item/started", %{
            "item" => %{"type" => "fileChange", "id" => "f1", "changes" => [%{"path" => "a"}]}
          }),
          note("item/completed", %{
            "item" => %{"type" => "fileChange", "id" => "f1", "status" => "failed"}
          }),
          note("item/started", %{
            "item" => %{
              "type" => "mcpToolCall",
              "id" => "m1",
              "server" => "docs",
              "tool" => "search",
              "arguments" => %{"q" => "x"}
            }
          }),
          note("item/completed", %{
            "item" => %{
              "type" => "mcpToolCall",
              "id" => "m1",
              "status" => "completed",
              "result" => %{"hits" => 2}
            }
          }),
          note("item/completed", %{
            "item" => %{"type" => "mcpToolCall", "id" => "m2", "status" => "completed"}
          }),
          note("item/started", %{"item" => %{"type" => "reasoning", "id" => "r"}}),
          note("item/completed", %{"item" => %{"type" => "reasoning", "id" => "r"}})
        ])

      assert [
               %{type: "tool_use", payload: %{name: "Edit"}},
               %{type: "tool_result", payload: %{tool_use_id: "f1", is_error: true}},
               %{type: "tool_use", payload: %{name: "docs:search", input: %{"q" => "x"}}},
               %{
                 type: "tool_result",
                 payload: %{tool_use_id: "m1", is_error: false, excerpt: ~s({"hits":2})}
               },
               %{type: "tool_result", payload: %{tool_use_id: "m2", excerpt: ""}}
             ] = events
    end

    test "a usage or windows report with nothing in it is nothing", %{state: state} do
      assert {[], [], _} =
               feed(state, [
                 note("thread/tokenUsage/updated", %{}),
                 note("account/rateLimits/updated", %{})
               ])
    end

    test "a window the account did not report is not drawn, and an unknown method is a notice", %{
      state: state
    } do
      {events, [], _} =
        feed(state, [
          note("account/rateLimits/updated", %{
            "rateLimits" => %{"primary" => %{"usedPercent" => nil}}
          }),
          note("thread/something/new", %{"x" => 1}),
          %{"neither" => "a request nor a response"}
        ])

      assert [
               %{
                 type: "rate_limit",
                 payload: %{rate_limit_type: "five_hour", utilization: nil, status: "allowed"}
               },
               %{type: "notice", payload: %{subtype: "thread/something/new"}},
               %{type: "unknown"}
             ] = events
    end

    test "an error notification is a notice, and a limit in it is the limit report", %{
      state: state
    } do
      {events, [], _} =
        feed(state, [note("error", %{"error" => %{"message" => "Usage limit reached"}})])

      assert [%{type: "notice"}, %{type: "rate_limit", payload: %{status: "rejected"}}] = events

      {quiet, [], _} = feed(state, [note("error", %{"message" => "boom"})])
      assert [%{type: "notice"}] = quiet
    end

    # A weekly limit read as the five-hour one blocked the credential for hours where it needed
    # days, and a limit with no report before it had no reset, so the job failed instead of going
    # back to pending.
    test "a usage limit is the window that was full, with that window's reset", %{state: state} do
      windows = fn primary, secondary ->
        note("account/rateLimits/updated", %{
          "rateLimits" => %{
            "primary" => %{"usedPercent" => primary, "resetsAt" => 1_800_000_000},
            "secondary" => %{"usedPercent" => secondary, "resetsAt" => 1_800_500_000}
          }
        })
      end

      limit = note("error", %{"error" => %{"message" => "You have hit your usage limit"}})

      limited = fn first ->
        {events, [], _} = feed(state, [first, limit])
        events |> List.last() |> Map.fetch!(:payload)
      end

      assert %{rate_limit_type: "seven_day", resets_at: 1_800_500_000} =
               limited.(windows.(30, 100))

      assert %{rate_limit_type: "five_hour", resets_at: 1_800_000_000} =
               limited.(windows.(100, 30))

      # Both full: the later reset, which is how long the credential is actually shut.
      assert %{rate_limit_type: "seven_day", resets_at: 1_800_500_000} =
               limited.(windows.(100, 100))

      # Neither reported full: the fullest.
      assert %{rate_limit_type: "seven_day"} = limited.(windows.(40, 90))
    end

    test "a usage limit with no report before it still has a reset to wait for", %{state: state} do
      {events, [], _} =
        feed(state, [note("error", %{"error" => %{"message" => "You have hit your usage limit"}})])

      assert %{type: "rate_limit", payload: %{rate_limit_type: "five_hour", resets_at: reset}} =
               List.last(events)

      assert_in_delta reset, System.os_time(:second) + 5 * 3600, 5
    end

    test "an interrupted turn ends as an error result that is not a failure", %{state: state} do
      {events, [], _} =
        feed(state, [note("turn/completed", %{"turn" => %{"status" => "interrupted"}})])

      assert [%{type: "finished", payload: %{subtype: "error_during_execution", is_error: false}}] =
               events
    end

    test "a refused turn ends the turn with the server's words", %{state: state} do
      {_e, _b, state} = feed(state, [note("turn/started", %{"turn" => %{"id" => "t"}})])
      {state, id} = {state, state.next_id}
      {_bytes, state} = Codex.send_message("again", %{state | busy: false})
      id = max(id, state.next_id - 1)

      {events, _b, _s} = feed(state, [%{"id" => id, "error" => %{"message" => "no capacity"}}])
      assert [%{type: "finished", payload: %{is_error: true, result: "no capacity"}}] = events
    end

    test "a thread that could not be started ends the run" do
      {id, _method, state} = ready()
      {events, _b, _s} = feed(state, [%{"id" => id, "error" => %{"message" => "no"}}])

      assert [
               %{
                 type: "finished",
                 payload: %{is_error: true, result: "the thread could not be started"}
               }
             ] = events
    end

    test "an answer to something no longer remembered, and an interrupt's own, change nothing", %{
      state: state
    } do
      assert {[], [], _} = feed(state, [%{"id" => 99, "result" => %{}}])
    end

    test "the stateless callbacks a behaviour asks for answer and raise nothing" do
      assert [_, "\n"] = Codex.encode_message("hi")
      assert Codex.encode_interrupt("r") == []
      assert Codex.parse_line("{}") == []
    end
  end

  describe "command/3" do
    test "the login reaches the process as a secret variable and never in argv" do
      {exe, args, env} =
        Codex.command(nil, "/jobs/j", credential: {:chatgpt_login, ~s({"tokens":{}})})

      assert exe == "/bin/sh"
      assert {"FORGE_CODEX_AUTH", {:secret, ~s({"tokens":{}})}} in env
      assert {"CODEX_ACCESS_TOKEN", false} in env
      refute Enum.any?(args, &String.contains?(&1, "tokens"))

      # What the prefix does with it: written under umask 077 to CODEX_HOME's auth.json, unset,
      # and Codex exec'd.
      [_c, prefix | _] = args
      assert prefix =~ "umask 077"
      assert prefix =~ ~s(> "$CODEX_HOME/auth.json")
      assert prefix =~ "unset FORGE_CODEX_AUTH"
      assert prefix =~ ~s(exec "$@")

      assert Enum.take(args, -4) == [
               "codex",
               "app-server",
               "-c",
               "check_for_update_on_startup=false"
             ]
    end

    test "an access token is a secret variable of its own, and the login's is absent" do
      {_exe, _args, env} = Codex.command(nil, "/jobs/j", credential: {:access_token, "tok"})
      assert {"CODEX_ACCESS_TOKEN", {:secret, "tok"}} in env
      assert {"FORGE_CODEX_AUTH", false} in env
    end

    test "no credential gives the process none, and a function that opens one is called" do
      {_e, _a, env} = Codex.command(nil, "/j", credential: nil)
      assert {"FORGE_CODEX_AUTH", false} in env

      {_e, _a, env} = Codex.command(nil, "/j", credential: fn -> {:access_token, "late"} end)
      assert {"CODEX_ACCESS_TOKEN", {:secret, "late"}} in env
    end
  end

  test "it offers its own name and the levels it takes, and no model list" do
    offer = Codex.probe(codex_executable: "/nonexistent/codex")
    assert %{driver: "codex", name: "Codex", version: nil, aliases: []} = offer
    assert "high" in offer.efforts
  end

  # Claude Code's `FORGE_CLAUDE_EXECUTABLE` arrives as `:executable`. Reading it here made the image
  # probe, and spawn, `claude app-server` as Codex.
  @tag :tmp_dir
  test "its binary is :codex_executable and never Claude Code's :executable", %{tmp_dir: dir} do
    exe = Path.join(dir, "codex")
    File.write!(exe, "#!/bin/sh\necho 'codex-cli 9.9.9'\n")
    File.chmod!(exe, 0o755)

    assert Codex.probe(codex_executable: exe).version == "9.9.9"
    assert Codex.probe(executable: exe).version == nil

    {_exe, args, _env} = Codex.command(nil, "/j", executable: "/opt/claude")
    refute "/opt/claude" in args
    assert "codex" in args
  end
end
