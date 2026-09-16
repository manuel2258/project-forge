defmodule Forge.BacklogTest do
  @moduledoc """
  What a job is handed when it wants to know what else exists.

  Three claims that are invisible when they hold and silent when they break: only this
  project's tickets, bodies and never artifacts, and open proposals beside the tickets so the
  same follow-up is not proposed three times.
  """

  use Forge.DataCase, async: true

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.{Artifacts, Backlog, Projects, Proposals}
  alias ForgeCore.Workflow

  defp file(backlog, name),
    do: Enum.find(backlog["tickets"] ++ backlog["proposals"], &(&1["file"] == name))

  describe "compose/2" do
    test "a file per ticket, named after its number, holding its body" do
      project = project_fixture()
      ticket_fixture(%{project: project, number: 12, title: "Scores vanish", body: "On restart."})

      backlog = Backlog.compose(project)

      assert %{"content" => content} = file(backlog, "12.md")
      assert content =~ "# Scores vanish"
      assert content =~ "On restart."
      assert content =~ "ticket 12"
    end

    test "the index names every ticket and says when it was taken" do
      project = project_fixture()
      ticket_fixture(%{project: project, number: 12, title: "Scores vanish"})
      ticket_fixture(%{project: project, number: 13, title: "Leaderboard sorts up"})

      now = ~U[2026-09-15 21:30:00Z]
      index = Backlog.compose(project, now)["index"]

      assert index =~ "2026-09-15T21:30:00Z"
      assert index =~ "Scores vanish"
      assert index =~ "Leaderboard sorts up"
      assert index =~ "| 12 |"
    end

    test "never reaches into another project" do
      project = project_fixture()
      other = project_fixture()
      ticket_fixture(%{project: other, number: 99, title: "Not yours"})

      backlog = Backlog.compose(project)

      assert backlog["tickets"] == []
      refute backlog["index"] =~ "Not yours"
    end

    # The rule that keeps "artifacts are the contract" true. Another ticket's plan is reasoning
    # at a version this job did not pin and cannot be approved on its behalf; a job building on
    # one would be building on something outside its manifest.
    test "carries bodies and never another ticket's artifacts" do
      project = project_fixture()
      ticket = ticket_fixture(%{project: project, number: 12, title: "Scores vanish"})
      job = job_fixture(%{ticket: ticket})

      {:ok, _version} =
        Artifacts.record_version(ticket.id, "plan.md", :document, {:job, job.id}, %{
          content: "---\noutcome: done\n---\n# Plan\n\nA secret plan nobody else may read.",
          parse: false
        })

      backlog = Backlog.compose(project)

      refute Enum.any?(backlog["tickets"], &(&1["content"] =~ "secret plan"))
      refute backlog["index"] =~ "plan.md"
    end

    # A person may edit a ticket after admission. The row's `body` is what was admitted; the
    # latest `ticket` document is what it now says, and an agent reading the older one would be
    # reading a description that was corrected precisely because it was wrong.
    test "uses the ticket document's latest version, not the row as admitted" do
      project = project_fixture()
      ticket = ticket_fixture(%{project: project, number: 12, title: "Vague", body: "Fix it."})

      {:ok, _version} =
        Artifacts.record_version(
          ticket.id,
          Workflow.ticket_artifact(),
          :document,
          {:user, user_fixture().id},
          %{content: "# Sharper\n\nThe leaderboard sorts ascending.", parse: false}
        )

      assert %{"content" => content} = file(Backlog.compose(project), "12.md")
      assert content =~ "The leaderboard sorts ascending."
      refute content =~ "Fix it."
    end

    # The whole reason the backlog exists. A proposal is a document rather than a ticket row, so
    # a composer written the obvious way — a query over `tickets` — leaves it out, and three
    # jobs each propose the same missing module.
    test "open proposals sit beside the tickets, with their titles in the index" do
      project = project_fixture()
      ticket = ticket_fixture(%{project: project, number: 12})
      job = job_fixture(%{ticket: ticket})
      proposal_fixture(%{job: job, title: "Extract the score table"})

      backlog = Backlog.compose(project)
      name = Workflow.proposal_artifact("score-table.md")

      assert %{"content" => content} = file(backlog, name)
      assert content =~ "Extract the score table"
      assert backlog["index"] =~ "Extract the score table"
      assert backlog["index"] =~ "Do not propose these again"
    end

    # Artifact names are unique per *job*, so two jobs proposing `follow-up.md` are two
    # different artifacts with the same name. Keyed by name, the second overwrote the first on
    # the worker's disk while the index listed both — telling the agent "do not propose these
    # again" about a file holding someone else's text, which is the one promise the backlog
    # exists to keep.
    test "two jobs proposing the same filename each get their own file" do
      project = project_fixture()
      ticket = ticket_fixture(%{project: project})
      a = job_fixture(%{ticket: ticket, attempt: 1})
      b = job_fixture(%{ticket: ticket, attempt: 2})

      proposal_fixture(%{job: a, file: "follow-up.md", title: "From job A"})
      proposal_fixture(%{job: b, file: "follow-up.md", title: "From job B"})

      backlog = Backlog.compose(project)
      names = Enum.map(backlog["proposals"], & &1["file"])

      assert length(names) == 2
      assert length(Enum.uniq(names)) == 2

      contents = Enum.map(backlog["proposals"], & &1["content"])
      assert Enum.any?(contents, &(&1 =~ "From job A"))
      assert Enum.any?(contents, &(&1 =~ "From job B"))

      # And the index has to point at the files that exist, or it is worse than useless.
      for name <- names, do: assert(backlog["index"] =~ name)
    end

    test "a decided proposal is gone from the backlog" do
      project = project_fixture()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      version = proposal_fixture(%{job: job, title: "Extract the score table"})

      {:ok, _decision} = Proposals.decline(version.id, user_fixture().id, "no")

      backlog = Backlog.compose(project)

      assert backlog["proposals"] == []
      refute backlog["index"] =~ "Extract the score table"
    end

    # It is open, so an agent that cannot see it proposes the same thing again. A filter would
    # be the tidier code and the wrong behaviour.
    test "a proposal that no longer parses is still listed, marked as unreadable" do
      project = project_fixture()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      proposal_fixture(%{job: job, content: "no heading at all"})

      backlog = Backlog.compose(project)

      assert length(backlog["proposals"]) == 1
      assert backlog["index"] =~ "(unreadable)"
    end

    test "a project with nothing in it composes an index that says so" do
      backlog = Backlog.compose(project_fixture())

      assert backlog["tickets"] == []
      assert backlog["proposals"] == []
      assert backlog["index"] =~ "No tickets yet."
      assert backlog["index"] =~ "None."
    end

    # A title with a pipe would split the row and shift every column after it, so the table
    # would say a ticket is in a state it is not.
    test "a title that would break the table is escaped" do
      project = project_fixture()
      ticket_fixture(%{project: project, number: 12, title: "Fix a | b parsing"})

      row =
        Backlog.compose(project)["index"]
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "| 12 |"))

      assert row =~ "Fix a \\| b parsing"

      # Four columns means five cell boundaries. `String.split/3` does not know about the
      # backslash, so the pipes are counted with one that does.
      assert ~r/(?<!\\)\|/ |> Regex.scan(row) |> length() == 5
    end
  end

  describe "the hash" do
    test "is stable for the same content and changes when a ticket does" do
      project = project_fixture()
      ticket = ticket_fixture(%{project: project, number: 12, title: "Scores vanish"})
      now = ~U[2026-09-15 21:30:00Z]

      first = Backlog.compose(project, now)["hash"]
      assert Backlog.compose(project, now)["hash"] == first

      Forge.Repo.update!(Ecto.Changeset.change(ticket, title: "Scores vanish on restart"))

      assert Backlog.compose(project, now)["hash"] != first
    end

    # The index carries titles, not bodies, so a hash taken over the index alone looks correct
    # on every test that edits a title. A snapshot whose hash misses the bodies is not
    # reproducible from the log, which is the whole reason the hash exists.
    test "changes when only a ticket's body changed" do
      project = project_fixture()
      ticket = ticket_fixture(%{project: project, number: 12, title: "Scores vanish"})
      now = ~U[2026-09-15 21:30:00Z]

      before = Backlog.compose(project, now)["hash"]

      {:ok, _version} =
        Artifacts.record_version(
          ticket.id,
          Workflow.ticket_artifact(),
          :document,
          {:user, user_fixture().id},
          %{content: "# Scores vanish\n\nA different body, the same title.", parse: false}
        )

      assert Backlog.compose(project, now)["hash"] != before
    end

    # The mirror of the ticket-body case, and it was missing. "changes when a proposal is added"
    # passes on the index alone, because the index gains a row; a proposal whose *body* is
    # rewritten while its title stays put changes no index row at all. Without this the hash
    # does not identify the snapshot, which is the only thing making it reproducible.
    test "changes when only a proposal's body changed" do
      user = user_fixture()
      project = project_fixture()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      now = ~U[2026-09-15 21:30:00Z]

      proposal_fixture(%{job: job, title: "Extract the score table", body: "One reason."})
      before = Backlog.compose(project, now)["hash"]

      {:ok, _second} =
        Artifacts.record_version(
          {:job, job.id},
          Workflow.proposal_artifact("score-table.md"),
          :document,
          {:user, user.id},
          %{content: "# Extract the score table\n\nA different reason.", parse: false}
        )

      assert Backlog.compose(project, now)["hash"] != before
    end

    # Without it the snapshot is unreproducible, which is the one thing that keeps
    # `decisions.md`'s "pinned by version" promise intact for a thing that has no version.
    test "changes when a proposal is added" do
      project = project_fixture()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      now = ~U[2026-09-15 21:30:00Z]

      before = Backlog.compose(project, now)["hash"]
      proposal_fixture(%{job: job})

      assert Backlog.compose(project, now)["hash"] != before
    end
  end

  describe "the assignment" do
    test "carries the backlog for a workflow job, and logs its hash" do
      project = project_fixture()
      ticket = ticket_fixture(%{project: project, number: 12, title: "Scores vanish"})

      job =
        job_fixture(%{
          ticket: ticket,
          spec: %{"prompt" => "agents/refine.md", "budget" => %{"turns" => 5, "cost" => 1.0}}
        })

      assignment = Forge.Jobs.assignment(job, ticket, Projects.get!(project.id), "token")

      assert assignment["backlog"]["index"] =~ "Scores vanish"
      assert assignment["backlog"]["hash"] =~ ~r/^[0-9a-f]{64}$/
    end

    test "carries it for a conversation too, which has no ticket at all" do
      project = project_fixture()
      ticket_fixture(%{project: project, number: 12, title: "Scores vanish"})
      chat = chat_fixture(%{project: project})

      assignment = Forge.Jobs.assignment(chat, nil, Projects.get!(project.id), "token")

      assert assignment["backlog"]["index"] =~ "Scores vanish"
    end
  end
end
