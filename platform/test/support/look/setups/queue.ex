defmodule Forge.Look.Setups.Queue do
  @moduledoc """
  The queue with one item of each kind (`docs/design/ui.md` § The queue): an approval with a
  changeset and the message it will commit (`18a`), two blocking questions on `brief.md` v2 with
  what the agent said (`13b`), a ticket stuck after running out of turns with its error and closing
  words (`13c`), and a chat asking a question; two tickets under way and one assumption, for the
  end of the pass (`13d`). The member last looked at the questions' ticket a day ago, and three
  things happened since.

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
