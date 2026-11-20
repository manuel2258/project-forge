defmodule Forge.Look.Setups.Queue do
  @moduledoc """
  The queue with one item of each kind (`docs/design/ui.md` § The queue): an approval with a
  changeset and the message it will commit (`18a`), two blocking questions on `brief.md` v2 with
  what the agent said (`13b`), a ticket stuck after running out of turns with its error and closing
  words (`13c`), and a chat asking a question; for the end of the pass (`13d`), one assumption and
  **Open tickets** (ticket 53): two waiting for a machine, one running on one with its usage and
  latest line, and one with a long title and a latest line that is markup; and
  **On hold** (ticket 63): a held ticket with an approval and two blocking questions waiting, and
  a held stuck one whose title is markup. The member last looked at the questions' ticket a day
  ago, and three things happened since.

  Users: `member`. Paths: `queue`, `approval`, `questions`, `stuck`, `chat`, `end`.
  Built as `Forge.Look.Setups.Decision` builds — git plumbing and recorded rows, no worker.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures

  alias Forge.{Artifacts, Conversations, Jobs, Repo, Tickets}
  alias Forge.Events.Event
  alias Forge.Look.Setups.Decision

  @workflow Path.expand("../../../../../core/test/fixtures/workflow_example.yml", __DIR__)
  @external_resource @workflow

  @impl true
  def build do
    member = user_fixture()
    project = Decision.project!("look-queue", File.read!(@workflow), member)

    approval = Decision.changeset_ticket!(project, member)
    {questions, version} = questions!(project, member)
    stuck = stuck!(project, member)
    chat = chat!(project)
    assumption!(project, member)

    for title <- ["Persist the high score table", "Score flickers on resize"],
        do: {:ok, _} = Tickets.admit(project, %{title: title}, {:user, member.id})

    running!(project, member)
    hostile!(project, member)
    held!(project, member)

    looked!(member, questions)

    %{
      users: %{"member" => member},
      paths: %{
        "queue" => "/",
        "approval" => "/?item=approval-#{approval.id}",
        "questions" => "/?item=questions-#{version.id}",
        "stuck" => "/?item=stuck-#{stuck.id}",
        "chat" => "/?item=chat-#{chat.id}",
        "end" => "/?item=end"
      }
    }
  end

  defp questions!(project, member) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Shape the leaderboard screen"}, {:user, member.id})

    [job] = Jobs.for_ticket(ticket.id)

    {:ok, _v1} =
      Artifacts.record_version(ticket.id, "brief.md", :document, {:job, job.id}, %{
        content: "---\noutcome: done\n---\n# Leaderboard\n\nThe top ten.\n"
      })

    {:ok, version} =
      Artifacts.record_version(ticket.id, "brief.md", :document, {:job, job.id}, %{
        content: """
        ---
        outcome: done
        ---
        # Leaderboard

        The top ten, and your own row pinned beneath them.

        ```question
        key: rank
        text: Outside the top 10, what does your row show?
        options:
          - {label: Your rank and score, detail: One count over the table per view., recommended: true}
          - {label: Only your score, detail: No count; the row reads 2 300.}
        blocking: true
        ```

        ```question
        key: empty
        text: What does an empty table show?
        options:
          - {label: A placeholder row, detail: "Be the first: play a round."}
          - {label: Nothing until the first score, detail: The screen is hidden until then.}
        blocking: true
        ```
        """
      })

    said!(
      ticket,
      job,
      "Two things the brief leaves open before I can call it shaped. When you're outside " <>
        "the top 10, the pinned row could show your rank or just your score."
    )

    {ticket, version}
  end

  defp stuck!(project, member) do
    {:ok, ticket} =
      Tickets.admit(
        project,
        %{title: "Replace the font atlas with a single SDF texture"},
        {:user, member.id}
      )

    [job] = Jobs.for_ticket(ticket.id)

    job =
      job
      |> Ecto.Changeset.change(
        state: "implementing",
        status: :finished,
        outcome: :did_not_converge,
        turns: 30,
        started_at: DateTime.add(DateTime.utc_now(:second), -760),
        finished_at: DateTime.add(DateTime.utc_now(:second), -60)
      )
      |> Repo.update!()

    insert!(ticket, job, "job.finished", %{
      "outcome" => "did_not_converge",
      "reason" => "3 tests failing in shader_test.exs\nsdf sampling at 8px is blurry"
    })

    said!(
      ticket,
      job,
      "Out of turns with the small sizes still blurry. More turns, or a smaller target such " <>
        "as 12px and up, would finish it."
    )

    ticket = ticket |> Ecto.Changeset.change(state: "implementing") |> Repo.update!()
    {:ok, ticket} = Forge.Engine.stick(ticket, "it ran out of turns")
    ticket
  end

  defp chat!(project) do
    {:ok, chat} = Conversations.open(project, "Why is the build so slow on CI?")

    :ok =
      Jobs.record_harness_event(chat.id, %{
        type: "job.harness.text",
        payload: %{
          text: """
          The cache key includes the commit, so nothing is ever reused.

          ```question
          key: key
          text: Key the cache on the lockfile instead?
          options:
            - {label: Yes, detail: Rebuilds only when dependencies move., recommended: true}
            - {label: No, detail: Keep it as it is.}
          ```
          """
        }
      })

    {:ok, chat} =
      Conversations.record_turn(chat, %{
        "turn" => 1,
        "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"}
      })

    chat
  end

  # Open tickets: running on a machine, with usage and the agent's latest line.
  defp running!(project, member) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Replace the sprite sheet loader"}, {:user, member.id})

    [job] = Jobs.for_ticket(ticket.id)
    {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
    started = DateTime.add(DateTime.utc_now(:second), -260)

    job
    |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id, started_at: started})
    |> Repo.update!()

    Repo.insert!(%Jobs.Run{job_id: job.id, worker_id: worker.id, started_at: started})
    ticket |> Ecto.Changeset.change(usage: 38_000) |> Repo.update!()
    said!(ticket, job, "Reading the loader's callers before I change its signature.")
  end

  # A long title and a latest line that is markup: cut where the Tickets list cuts, and text.
  defp hostile!(project, member) do
    {:ok, ticket} =
      Tickets.admit(
        project,
        %{
          title:
            "Rework the whole leaderboard pipeline so that weekly resets, regional boards and " <>
              "friends-only views all read from one materialised table instead of three"
        },
        {:user, member.id}
      )

    [job] = Jobs.for_ticket(ticket.id)
    said!(ticket, job, "<b>Plan:</b> <script>alert(1)</script> start with the table.")
  end

  # On hold with decisions waiting: no item and no count, a row each in **On hold**. Started — a job
  # with a start — because a held ticket that never ran asks nothing.
  defp held!(project, member) do
    {:ok, asking} = Tickets.admit(project, %{title: "Cache the font atlas"}, {:user, member.id})
    start!(asking)

    {:ok, _} =
      Artifacts.record_version(asking.id, "brief.md", :document, :system, %{
        content: """
        ---
        outcome: done
        ---
        # Brief

        ```question
        key: size
        text: How big may it grow?
        options: [{label: 64 MB, detail: Tight.}, {label: 256 MB, detail: Roomy.}]
        blocking: true
        ```

        ```question
        key: evict
        text: What goes first when it is full?
        options: [{label: Oldest, detail: By age.}, {label: Largest, detail: By size.}]
        blocking: true
        ```
        """
      })

    asking
    |> Ecto.Changeset.change(
      pending_transition: %{"from" => asking.state, "to" => "planning", "approve" => []},
      held_at: DateTime.utc_now(:second)
    )
    |> Repo.update!()

    {:ok, stuck} =
      Tickets.admit(
        project,
        %{title: "<i>Rotate</i> the signing keys & <script>alert(1)</script>"},
        {:user, member.id}
      )

    start!(stuck)
    {:ok, stuck} = Forge.Engine.stick(stuck, "it ran out of turns")
    stuck |> Ecto.Changeset.change(held_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp start!(ticket) do
    [job] = Jobs.for_ticket(ticket.id)
    job |> Ecto.Changeset.change(started_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp assumption!(project, member) do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, member.id})
    [job] = Jobs.for_ticket(ticket.id)

    {:ok, _} =
      Artifacts.record_version(ticket.id, "plan.md", :document, {:job, job.id}, %{
        content: """
        ---
        outcome: done
        ---
        # Plan

        ```question
        key: path
        text: Where does the score file live?
        options: [{label: data dir, detail: Beside the jobs., recommended: true}, {label: home, detail: The user's own.}]
        blocking: false
        assumption: $FORGE_DATA_DIR/scores.db
        ```
        """
      })
  end

  # The member opened the questions' ticket a day ago; since then it moved into shaping and they
  # said two things in its conversation.
  defp looked!(member, ticket) do
    Repo.insert!(%Forge.Tickets.View{
      user_id: member.id,
      ticket_id: ticket.id,
      viewed_at: DateTime.add(DateTime.utc_now(), -86_400)
    })

    old = %{"kind" => "system", "id" => nil}
    you = %{"kind" => "user", "id" => member.id}

    for {type, actor, payload, ago} <- [
          {"transition.taken", old, %{"from" => "triage", "to" => "shaping"}, 1860},
          {"chat.message", you, %{"text" => "We need a leaderboard players can actually see."},
           1500},
          {"chat.message", you, %{"text" => "Keep it to one screen."}, 540}
        ] do
      Repo.insert!(%Event{
        ticket_id: ticket.id,
        project_id: ticket.project_id,
        actor: actor,
        type: type,
        payload: payload,
        inserted_at: DateTime.add(DateTime.utc_now(:second), -ago)
      })
    end
  end

  defp said!(ticket, job, text) do
    insert!(ticket, job, "job.harness.text", %{"text" => text})
  end

  defp insert!(ticket, job, type, payload) do
    Repo.insert!(%Event{
      ticket_id: ticket.id,
      project_id: ticket.project_id,
      job_id: job.id,
      actor: %{"kind" => "job", "id" => job.id},
      type: type,
      payload: payload
    })
  end
end
