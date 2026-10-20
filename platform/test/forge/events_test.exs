defmodule Forge.EventsTest do
  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  alias Ecto.Multi
  alias Forge.Events
  alias Forge.Events.Event

  test "append/3 writes an ordered, typed event" do
    ticket = ticket_fixture()

    {:ok, first} =
      Events.append("ticket.admitted", :system, %{
        ticket_id: ticket.id,
        payload: %{"state" => "refining"}
      })

    {:ok, second} =
      Events.append("ticket.noted", {:user, Ecto.UUID.generate()}, %{ticket_id: ticket.id})

    assert first.seq < second.seq
    assert first.actor == %{"kind" => "system", "id" => nil}

    assert [%Event{type: "ticket.admitted"}, %Event{type: "ticket.noted"}] =
             Events.for_ticket(ticket.id)
  end

  test "log/5 inserts inside a multi and may read earlier changes" do
    ticket = ticket_fixture()

    {:ok, %{job: job, event: event}} =
      Multi.new()
      |> Multi.insert(
        :job,
        Forge.Jobs.Job.create_changeset(%Forge.Jobs.Job{}, %{
          ticket_id: ticket.id,
          project_id: ticket.project_id,
          state: "refining",
          attempt: 1,
          spec: %{},
          memory_max: Forge.Jobs.default_resources().memory,
          cores: Forge.Jobs.default_resources().cores
        })
      )
      |> Events.log(:event, "job.created", :system, fn %{job: job} ->
        %{ticket_id: ticket.id, job_id: job.id}
      end)
      |> Repo.transaction()

    assert event.job_id == job.id
    assert [%Event{type: "job.created"}] = Events.for_job(job.id)
  end

  test "rejects malformed types and actors" do
    assert {:error, changeset} = Events.append("nodots", :system)
    assert %{type: [_]} = errors_on(changeset)

    assert %{type: [_]} = errors_on(Event.changeset(%Event{}, %{type: "ticket.admitted\n"}))

    assert %{actor: [_]} =
             errors_on(Event.changeset(%Event{}, %{type: "a.b", actor: %{"kind" => "ghost"}}))
  end

  # `summary/1` is a bounded line for lists and the CLI's log; `detail/1` is the same rendering
  # whole, for the job's stream, which clips it itself (`docs/design/ui.md` § Activity).
  describe "detail/1" do
    test "is the whole of what summary/1 cuts short" do
      long = String.duplicate("word ", 2000)

      text = %Event{type: "job.harness.text", payload: %{"text" => long}}
      assert Events.detail(text) == long
      assert Events.summary(text) == String.slice(long, 0, 200)

      message = %Event{type: "chat.message", payload: %{"text" => long}}
      assert Events.detail(message) == long
      assert Events.summary(message) == String.slice(long, 0, 200)

      other = %Event{type: "job.harness.retry", payload: %{"error" => long}}
      assert Events.detail(other) == ~s(error=#{inspect(long)})
      assert Events.summary(other) == String.slice(~s(error=#{inspect(long)}), 0, 160)
    end

    test "is summary/1 where summary/1 already says all of it" do
      event = %Event{type: "chat.turn", payload: %{"turn" => 3}}
      assert Events.detail(event) == Events.summary(event)
    end
  end

  # A conversation's request that moved nothing is drawn in the job's Activity stream like any
  # other event, through `detail/1` (`work_screen.ex`). Rendered as the reason and not as the
  # payload, or the person reads a JSON blob where a sentence should be
  # (`docs/design/conversations.md` § Taking a transition).
  describe "summary/1 of a refused transition" do
    test "reads as the reason, not the request" do
      event = %Event{
        type: "chat.transition_refused",
        payload: %{
          "request" => %{"to" => "planning"},
          "reason" => "`refinement.md` has no version yet, so nothing can approve it"
        }
      }

      assert Events.summary(event) ==
               "`refinement.md` has no version yet, so nothing can approve it"
    end

    test "is cut short in a list and whole in the stream" do
      long = String.duplicate("word ", 200)
      event = %Event{type: "chat.transition_refused", payload: %{"reason" => long}}

      assert Events.summary(event) == String.slice(long, 0, 160)
      assert Events.detail(event) == long
    end
  end

  describe "summary/1 of commands" do
    test "reads as what ran and how it ended" do
      sha = String.duplicate("a", 40)

      assert Events.summary(%Event{
               type: "command.invoked",
               payload: %{"command" => "build", "args" => ["--release", "a b"], "commit" => sha}
             }) == ~s($ build ["--release","a b"] at aaaaaaaaaaaa)

      assert Events.summary(%Event{
               type: "command.finished",
               payload: %{
                 "command" => "test",
                 "args" => [],
                 "exit_status" => 2,
                 "outcome" => "converged"
               }
             }) == "test: exit 2"

      assert Events.summary(%Event{
               type: "command.finished",
               payload: %{"command" => "test", "exit_status" => nil, "outcome" => "error"}
             }) == "test: error"

      assert Events.summary(%Event{
               type: "job.parked",
               payload: %{"invocations" => [%{"job_id" => "x"}, %{"refused" => "no"}]}
             }) == "parked on 1 command, 1 refused"

      assert Events.summary(%Event{
               type: "commands.started",
               payload: %{"jobs" => ["a", "b"], "at" => sha}
             }) == "2 commands at aaaaaaaaaaaa"

      assert Events.summary(%Event{
               type: "commands.decided",
               payload: %{"statuses" => [0, nil], "outcome" => "checks_failed"}
             }) == "statuses 0, none → checks_failed"
    end
  end

  # `docs/design/claude-code-events.md` § Memory: the worker's readings as sentences, the words
  # `Forge.Jobs.Memory` gives the header and the now line.
  # The rail's last four events say what a conflict means beside its type (`ui.md` § Decide and
  # Timeline): the first path, how many more, and the state that would have merged.
  describe "summary/1 of a merge conflict" do
    test "names the first path, how many more, and where it was going" do
      conflicted = fn paths ->
        Events.summary(%Event{
          type: "ticket.merge_conflicted",
          payload: %{"state" => "merged", "paths" => paths}
        })
      end

      assert conflicted.(["README.md"]) == "README.md conflicted on the way into merged"

      assert conflicted.(["AppState.kt", "Store.kt", "ui/HomeScreen.kt"]) ==
               "AppState.kt and 2 more conflicted on the way into merged"

      assert conflicted.([]) == "conflicted on the way into merged"
    end
  end

  describe "summary/1 of memory" do
    test "a memory event is its sentence" do
      assert Events.summary(%Event{
               type: "job.harness.memory",
               payload: %{
                 "what" => "oom_kill",
                 "oom_kills" => 2,
                 "peak" => 1024 ** 3,
                 "ceiling" => 2 * 1024 ** 3
               }
             }) == "a process was killed for memory (2 OOM kills · peak 1.0 GiB of 2 GiB)"
    end

    # 2026-09-29's first chat said nothing but the time; the second said what systemd-run did.
    test "a harness not started says how long, its last line of stderr, and its memory" do
      assert Events.summary(%Event{
               type: "job.harness.starting",
               payload: %{
                 "waited_s" => 120,
                 "gave_up" => false,
                 "stderr" => "",
                 "memory" => %{"current" => 0, "ceiling" => 2, "pressure" => 100.0}
               }
             }) == "not started after 120s · memory 0.0 GiB of 2 B · full pressure 100.0%"

      assert Events.summary(%Event{
               type: "job.harness.starting",
               payload: %{
                 "waited_s" => 1800,
                 "gave_up" => true,
                 "stderr" =>
                   "Running as unit: x\nFailed to start transient service unit: Connection timed out\n",
                 "memory" => nil
               }
             }) ==
               "not started after 1800s, gave up · stderr: Failed to start transient service " <>
                 "unit: Connection timed out"
    end
  end

  describe "summary/1" do
    # The clause order is the whole design of this function: the typed clauses render the events
    # a reader actually follows, the empty-payload clause keeps a bare event from rendering as
    # `%{}`, and the general clause is the fallback that inspects whatever is left. Its readers
    # are `Forge.CLI`'s event log, the job page's stream, and the wait reason the ticket and
    # conversation pages draw, and in each a wrong clause reads as an event that says nothing,
    # or says it as data, rather than as an error.

    test "an event with nothing to say says nothing" do
      assert Events.summary(%Event{type: "ticket.noted", payload: %{}}) == ""
    end

    # The agent wrote the call, and a name in the wrong type stays in the log for ever: the
    # line leaves it out rather than raising on it wherever the log is listed.
    test "summarises a call as its name and its input, bounded" do
      call = fn name, input ->
        Events.summary(%Event{
          type: "job.harness.tool_use",
          payload: %{"name" => name, "input" => input}
        })
      end

      assert call.("Bash", %{"command" => "mix test"}) == ~s(Bash {"command":"mix test"})
      assert call.(%{"not" => "a name"}, %{}) == " {}"
      assert call.("Write", %{"content" => String.duplicate("x", 500)}) |> String.length() == 166
    end

    test "an event with a payload says what is in it" do
      summary =
        Events.summary(%Event{type: "job.interrupted", payload: %{"reason" => "worker_lost"}})

      assert summary =~ "reason="
      assert summary =~ "worker_lost"
    end

    # A conversation's own words. Without the `chat.message` clause they would reach the log as
    # an inspected map — the line a person typed, rendered as data. See
    # `docs/design/conversations.md`.
    test "a chat message is the text, and a chat turn is its number" do
      assert Events.summary(%Event{type: "chat.message", payload: %{"text" => "are you there?"}}) ==
               "are you there?"

      assert Events.summary(%Event{type: "chat.turn", payload: %{"turn" => 3}}) == "turn 3"
    end

    # The scheduler's sentence, which the ticket and conversation pages draw under a waiting
    # job. The reason code beside it is for comparing passes, and the general clause would put
    # both on the page as data.
    test "a wait is the sentence the scheduler wrote, not its reason code" do
      event = %Event{
        type: "job.waiting",
        payload: %{"reason" => "at_capacity", "text" => "Waiting for room."}
      }

      assert Events.summary(event) == "Waiting for room."
    end

    test "a long message is bounded rather than filling the line" do
      text = String.duplicate("x", 500)

      assert Events.summary(%Event{type: "chat.message", payload: %{"text" => text}}) ==
               String.duplicate("x", 200)
    end
  end

  test "events can never be updated or deleted" do
    {:ok, event} = Events.append("ticket.noted", :system)

    assert_raise Postgrex.Error, ~r/events is append-only/, fn ->
      Repo.update!(Ecto.Changeset.change(event, type: "tampered.type"))
    end

    assert_raise Postgrex.Error, ~r/events is append-only/, fn -> Repo.delete!(event) end
  end
end
