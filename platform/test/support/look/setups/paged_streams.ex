defmodule Forge.Look.Setups.PagedStreams do
  @moduledoc """
  A job's stream, a ticket's Activity and a conversation's Talk that are longer than a page
  (`docs/design/ui.md` § Activity, § The job page, § Talk): a running job with three hundred
  events and a failure far back, an earlier job that was swept thirty days after it ended, a
  conversation of twenty-five turns, and a swept one. Users: `member`. Paths: `stream` (the job
  page), `swept` (the job that was swept), `activity` (the ticket's Activity), `talk` and
  `talk_swept`. Made from fixtures; the events are written directly, as the platform would have.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.{Events, Jobs, Repo}

  @impl true
  def build do
    member = user_fixture()
    project = project_fixture(%{name: "game"}) |> join!(member)

    ticket =
      ticket_fixture(%{
        project: project,
        number: 64,
        title: "Stop re-reading",
        state: "implementing"
      })

    swept = swept_job!(ticket)
    running = running_job!(ticket)

    chat = chat_fixture(%{project: project, ticket: nil})
    talk!(chat, 25)

    old = chat_fixture(%{project: project})
    talk!(old, 3, false)
    record(old, "job.swept", %{"removed" => 214, "days" => 30, "ended" => "2026-10-01T00:00:00Z"})

    job = &"/tickets/#{project.name}/#{ticket.number}/jobs/#{&1.id}"

    %{
      users: %{"member" => member},
      paths: %{
        "stream" => job.(running),
        "swept" => job.(swept),
        "activity" => "/tickets/#{project.name}/#{ticket.number}?tab=activity",
        "talk" => "/chats/#{chat.id}",
        "talk_swept" => "/chats/#{old.id}"
      }
    }
  end

  defp record(job, type, payload) do
    {:ok, event} =
      Events.append(type, {:job, job.id}, %{
        job_id: job.id,
        ticket_id: job.ticket_id,
        payload: payload
      })

    event
  end

  defp say(job, text), do: record(job, "job.harness.text", %{"text" => text})

  defp tool!(job, id, name, input, excerpt, error? \\ false) do
    record(job, "job.harness.tool_use", %{"id" => id, "name" => name, "input" => input})

    record(job, "job.harness.tool_result", %{
      "tool_use_id" => id,
      "is_error" => error?,
      "excerpt" => excerpt,
      "bytes" => byte_size(excerpt)
    })
  end

  # The job a sweep went over: what it said stays, and one line says what is gone.
  defp swept_job!(ticket) do
    job = job_fixture(%{ticket: ticket, state: "implementing", attempt: 1})
    said = say(job, "I'll look at how scores are kept today.")
    assert_seq(said)
    say(job, "The table lives in an Agent; I'll move it to a repo and keep `top/1`.")
    record(job, "job.swept", %{"removed" => 128, "days" => 30, "ended" => "2026-10-01T00:00:00Z"})

    job
    |> Jobs.Job.progress_changeset(%{
      status: :finished,
      outcome: :converged,
      finished_at: ~U[2026-10-01 12:00:00Z]
    })
    |> Repo.update!()
  end

  defp assert_seq(%{seq: seq}) when is_integer(seq), do: :ok

  # Three hundred events: a plan, a failing test a long way back, a hundred calls with their results
  # and a hundred sentences, and a passing test last.
  defp running_job!(ticket) do
    job = job_fixture(%{ticket: ticket, state: "implementing", attempt: 2, status: :running})

    tool!(job, "plan", "TodoWrite", %{"todos" => todos()}, "ok")

    tool!(
      job,
      "early",
      "Bash",
      %{"command" => "mix test test/game/scores_test.exs"},
      "1) test top/1 orders ties by time\n   left:  [\"bo\", \"al\"]\n   right: [\"al\", \"bo\"]",
      true
    )

    for n <- 1..100 do
      say(job, "Step #{n}: reading the next module and noting what it does to the score table.")

      tool!(job, "t#{n}", "Read", %{"file_path" => "lib/game/module_#{n}.ex"}, "ok")
    end

    tool!(job, "late", "Bash", %{"command" => "mix test"}, "46 tests, 0 failures")
    say(job, "All green. Committing.")
    job
  end

  defp todos do
    [
      %{
        "content" => "Read the scores module",
        "status" => "completed",
        "activeForm" => "Reading"
      },
      %{
        "content" => "Move the table to a repo",
        "status" => "in_progress",
        "activeForm" => "Moving"
      },
      %{"content" => "Run the tests", "status" => "pending", "activeForm" => "Testing"}
    ]
  end

  # A swept conversation has no tool calls left: that is what was swept.
  defp talk!(chat, turns, calls? \\ true) do
    for n <- 1..turns do
      record(chat, "chat.message", %{
        "text" => "Question number #{n}: how does the queue pick a credential?"
      })

      if calls?,
        do: tool!(chat, "q#{n}", "Read", %{"file_path" => "lib/forge/credentials.ex"}, "ok")

      say(
        chat,
        "Answer number #{n}: it passes over the rate-limited ones and prefers the one that has spent least today."
      )

      record(chat, "chat.turn", %{"turn" => n})
    end
  end
end
