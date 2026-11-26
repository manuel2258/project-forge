defmodule Forge.Look.Setups.Extend do
  @moduledoc """
  A job that ran out of budget and what a person can do about it (`docs/design/ui.md` § Steps,
  *Ways forward*, and § The job page): two tickets stuck in `implementing`, one with room to spare
  in its cap (`roomy`) and one with almost none (`short`, which draws the raise box), a ticket whose
  job was extended twice — with a note that is markup and a cap raised with the second — and is
  running again (`extended`, and its job's page, `job`), and a ticket stuck on a job that left no
  session, which has *Run again* alone (`nosession`).

  Users: `member`. Paths: `roomy`, `short`, `queue`, `extended`, `job`, `nosession`, and
  `restarted`, the page of a second attempt that a person's note started.
  Made from fixtures — no worker, no repository.
  """

  @behaviour Forge.Look.Setups

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.{Events, Repo}
  alias Forge.Jobs.{Extension, Job, Run}
  alias Forge.Tickets.CapRaise

  @impl true
  def build do
    member = user_fixture()
    project = project_fixture(%{name: "look-extend"}) |> join!(member)

    # Stopped by its time limit, which its state sets to three hours; the others by tokens, on the
    # engine's two.
    roomy =
      stuck!(project, "Persist the high score table", 2_100_000,
        exhausted: :timeout,
        timeout_ms: 10_800_000
      )

    short = stuck!(project, "Score flickers on resize", 4_600_000)
    nosession = stuck!(project, "Keep the table sorted", 2_100_000, session: false)
    {extended, job} = extended!(project, member)
    {restarted, again} = restarted!(project)

    %{
      users: %{"member" => member},
      paths: %{
        "roomy" => ticket_path(project, roomy),
        "short" => ticket_path(project, short),
        "queue" => "/",
        "extended" => ticket_path(project, extended),
        "job" => "#{ticket_path(project, extended)}/jobs/#{job.id}",
        "restarted" => "#{ticket_path(project, restarted)}/jobs/#{again.id}",
        "nosession" => ticket_path(project, nosession)
      }
    }
  end

  defp ticket_path(project, ticket), do: "/tickets/#{project.name}/#{ticket.number}"

  # Stuck in `implementing` after its job spent `usage` and ran out of tokens.
  defp stuck!(project, title, usage, opts \\ []) do
    ticket =
      ticket_fixture(%{project: project, title: title, state: "implementing", branch: "ticket/x"})
      |> Ecto.Changeset.change(status: :stuck, usage: usage)
      |> Repo.update!()

    {:ok, _} =
      Events.append("ticket.stuck", :system, %{
        ticket_id: ticket.id,
        payload: %{"reason" => "no transition from \"budget_exhausted\""}
      })

    finished!(ticket, usage, opts)
    ticket
  end

  defp finished!(ticket, usage, opts) do
    job =
      job_fixture(%{
        ticket: ticket,
        state: "implementing",
        harness: "claude_code",
        spec: spec(Keyword.get(opts, :timeout_ms))
      })

    session = if Keyword.get(opts, :session, true), do: session(job), else: nil
    now = DateTime.utc_now(:second)

    Repo.insert!(%Run{
      job_id: job.id,
      started_at: DateTime.add(now, -3_000, :second),
      finished_at: DateTime.add(now, -600, :second),
      usage: min(usage, 2_050_000)
    })

    job
    |> Job.progress_changeset(%{
      status: :finished,
      outcome: :budget_exhausted,
      exhausted: Keyword.get(opts, :exhausted, :tokens),
      turns: 118,
      usage: min(usage, 2_050_000),
      harness_session_id: session && "sess-look",
      session_blob: session,
      started_at: DateTime.add(now, -3_000, :second),
      finished_at: DateTime.add(now, -600, :second)
    })
    |> Repo.update!()
  end

  defp session(job), do: %{"key" => "job/#{job.id}/session-x/1.jsonl", "version" => "2.1.284"}

  # `timeout_ms` nil is a spec with no limit of its own, which runs on the engine's two hours.
  defp spec(timeout_ms \\ nil) do
    budget = %{"turns" => 200, "tokens" => 2_000_000}
    budget = if timeout_ms, do: Map.put(budget, "timeout_ms", timeout_ms), else: budget

    %{
      "prompt" => "Implement the plan.",
      "branch" => "ticket/x",
      "commit" => "9f3c1a0b2d4e6f8a",
      "budget" => budget,
      "inputs" => [],
      "outcomes" => ["done", "plan_invalid"],
      "produces" => ["implementation.md"]
    }
  end

  # Extended twice and reopened: the first extension on its own, the second raising the cap, with a
  # note that is markup and says two lines; the job has run once more on the first and is waiting
  # to run on the second.
  defp extended!(project, member) do
    ticket = stuck!(project, "Bring the leaderboard back", 4_300_000)
    [job] = Repo.all(from(j in Job, where: j.ticket_id == ^ticket.id))
    now = DateTime.utc_now(:second)

    first =
      extension!(
        job,
        member,
        1_000_000,
        100,
        14_400_000,
        "Finish the review.",
        DateTime.add(now, -500, :second)
      )

    second =
      extension!(
        job,
        member,
        1_500_000,
        120,
        5_400_000,
        "<b>Do not</b> re-read the schema:\nthe table is in lib/game/scores.ex.",
        DateTime.add(now, -60, :second)
      )

    for {extension, usage, started} <- [{first, 1_000_000, -480}] do
      Repo.insert!(%Run{
        job_id: job.id,
        started_at: DateTime.add(now, started, :second),
        finished_at: DateTime.add(now, started + 400, :second),
        usage: usage,
        extension_id: extension.id,
        resumed: true
      })
    end

    Repo.insert!(%CapRaise{
      ticket_id: ticket.id,
      user_id: member.id,
      from_tokens: 5_000_000,
      to_tokens: 6_000_000,
      extension_id: second.id
    })

    said!(ticket, job, member, first, "job.extended", -500)
    said!(ticket, job, member, second, "job.extended", -60)

    {:ok, _} =
      Events.append("ticket.cap_raised", {:user, member.id}, %{
        ticket_id: ticket.id,
        payload: %{"from" => 5_000_000, "to" => 6_000_000, "extension_id" => second.id}
      })

    {:ok, _} =
      Events.append("ticket.retried", {:user, member.id}, %{
        ticket_id: ticket.id,
        payload: %{"state" => "implementing", "note" => "From the top, smaller steps."}
      })

    job
    |> Job.progress_changeset(%{status: :pending, outcome: nil, exhausted: nil, finished_at: nil})
    |> Repo.update!()

    ticket =
      ticket |> Ecto.Changeset.change(status: :active, cap_raise: 1_000_000) |> Repo.update!()

    {ticket, job}
  end

  # A state run again with a note: the second attempt, whose arrival comment is that note — markup
  # and two lines, drawn as typed on the job page's manifest.
  defp restarted!(project) do
    ticket =
      ticket_fixture(%{
        project: project,
        title: "Start the table smaller",
        state: "implementing",
        branch: "ticket/x"
      })

    job =
      job_fixture(%{
        ticket: ticket,
        state: "implementing",
        harness: "claude_code",
        attempt: 2,
        spec:
          Map.put(spec(), "entered", %{
            "from" => "implementing",
            "by" => "person",
            "comment" => "<b>Start</b> with the sort order.\nThe rest can wait."
          })
      })

    {ticket, job}
  end

  # The event the extension wrote, as `Forge.Engine.extend/5` writes it.
  defp said!(ticket, job, member, extension, type, _seconds) do
    {:ok, _} =
      Events.append(type, {:user, member.id}, %{
        ticket_id: ticket.id,
        job_id: job.id,
        payload: %{
          "extension_id" => extension.id,
          "tokens" => extension.tokens,
          "turns" => extension.turns,
          "timeout_ms" => extension.timeout_ms,
          "note" => extension.note,
          "exhausted" => "tokens"
        }
      })
  end

  defp extension!(job, member, tokens, turns, timeout_ms, note, at) do
    Repo.insert!(%Extension{
      job_id: job.id,
      ticket_id: job.ticket_id,
      user_id: member.id,
      tokens: tokens,
      turns: turns,
      timeout_ms: timeout_ms,
      note: note,
      exhausted: :tokens,
      stopped_at: DateTime.add(at, -120, :second),
      usage_before: 2_050_000,
      turns_before: 118,
      runs_before: 1,
      inserted_at: DateTime.add(at, 0, :microsecond)
    })
  end
end
