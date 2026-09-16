defmodule Forge.ProposalsTest do
  @moduledoc """
  What a proposal is worth depends on three rules that are invisible when they hold.

  A decision attaches to an exact version, so editing a title before accepting reopens it. An
  accepted proposal becomes a ticket and a declined one leaves a record, because without the
  record the next job proposes the same thing. And a job may propose freely only because
  nothing it writes creates work — so the cap refuses loudly rather than dropping.
  """

  use Forge.DataCase, async: true

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures
  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.{Artifacts, Events, Jobs, Projects, Proposals, Repo, Tickets}
  alias Forge.Proposals.Decision
  alias ForgeCore.{Proposal, Workflow}

  defp registered_project do
    {:ok, project} =
      Projects.register(%{
        name: "game-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    project
  end

  describe "open/1" do
    test "lists a proposal, and stops listing it once it is decided" do
      user = user_fixture()
      job = job_fixture()
      project_id = job.project_id
      version = proposal_fixture(%{job: job})

      assert [%{version: %{id: id}, job: %{id: job_id}}] = Proposals.open(project_id)
      assert id == version.id
      assert job_id == job.id

      {:ok, _decision} = Proposals.decline(version.id, user.id, "not now")

      assert Proposals.open(project_id) == []
    end

    test "never reaches into another project" do
      job = job_fixture()
      proposal_fixture(%{job: job})

      assert Proposals.open(project_fixture().id) == []
    end

    # The rule `data-model.md` already states for approvals: a newer version has no decision
    # until it gets one. Editing a verbose title before accepting must reopen the proposal, not
    # inherit a decision made about text that is no longer there.
    test "a decision on an earlier version does not close a newer one" do
      user = user_fixture()
      job = job_fixture()
      first = proposal_fixture(%{job: job})

      {:ok, _} = Proposals.decline(first.id, user.id, nil)
      assert Proposals.open(job.project_id) == []

      {:ok, second} =
        Artifacts.record_version(
          {:job, job.id},
          Workflow.proposal_artifact("score-table.md"),
          :document,
          {:user, user.id},
          %{content: "# Shorter title\n\nSame work.", parse: false}
        )

      assert [%{version: %{id: id}}] = Proposals.open(job.project_id)
      assert id == second.id
    end

    # Two versions and no decision at all. Without the latest-version join the query returns
    # both, and the operator is offered the same proposal twice — once as text nobody has now.
    # The decision filter cannot catch this, which is why it is its own case.
    test "shows one row per proposal, not one per version" do
      user = user_fixture()
      job = job_fixture()
      proposal_fixture(%{job: job})

      {:ok, _second} =
        Artifacts.record_version(
          {:job, job.id},
          Workflow.proposal_artifact("score-table.md"),
          :document,
          {:user, user.id},
          %{content: "# Shorter title\n\nSame work.", parse: false}
        )

      assert [%{version: version}] = Proposals.open(job.project_id)
      assert version.version == 2
    end

    test "an ordinary job-scoped artifact is not a proposal" do
      job = job_fixture()

      {:ok, _version} =
        Artifacts.record_version({:job, job.id}, "notes.md", :document, {:job, job.id}, %{
          content: "# Notes\n\nnot a proposal",
          parse: false
        })

      assert Proposals.open(job.project_id) == []
    end

    test "open_for_ticket/1 shows only the proposals of that ticket's jobs" do
      ticket = ticket_fixture()
      mine = job_fixture(%{ticket: ticket})

      theirs =
        job_fixture(%{ticket: ticket_fixture(%{project: Projects.get!(ticket.project_id)})})

      version = proposal_fixture(%{job: mine})
      proposal_fixture(%{job: theirs, file: "other.md"})

      assert [%{version: %{id: id}}] = Proposals.open_for_ticket(ticket.id)
      assert id == version.id
    end
  end

  describe "accept/3" do
    test "admits a ticket from the proposal and records what it created" do
      user = user_fixture()
      project = registered_project()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})

      version =
        proposal_fixture(%{
          job: job,
          title: "Extract the score table",
          body: "The plan assumes a module that is not there."
        })

      assert {:ok, ticket} = Proposals.accept(version.id, user.id, "good idea")

      assert ticket.title == "Extract the score table"
      assert ticket.body == "The plan assumes a module that is not there."
      assert ticket.project_id == project.id

      decision = Proposals.decision(version.id)
      assert decision.decision == :accepted
      assert decision.ticket_id == ticket.id
      assert decision.comment == "good idea"

      assert Proposals.open(project.id) == []
    end

    # A proposal is not work in flight and holds nothing. It should run against whatever the
    # project declares when a person says go, not against whatever it declared when an agent
    # thought of it — and the opposite reading is plausible enough to be worth a test.
    test "pins the workflow at accept time, not at propose time" do
      user = user_fixture()
      project = registered_project()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      version = proposal_fixture(%{job: job})

      {:ok, ticket} = Proposals.accept(version.id, user.id)

      {:ok, head} = Forge.Git.resolve(Projects.repo_path(project), project.default_branch)
      assert ticket.workflow_commit == head
    end

    test "the admitted ticket is attributed to the person, not to the job" do
      user = user_fixture()
      project = registered_project()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      version = proposal_fixture(%{job: job})

      {:ok, ticket} = Proposals.accept(version.id, user.id)

      assert [admitted] =
               ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == "ticket.admitted"))

      assert admitted.actor == %{"kind" => "user", "id" => user.id}
    end

    test "refuses a proposal that has already been decided" do
      user = user_fixture()
      project = registered_project()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      version = proposal_fixture(%{job: job})

      {:ok, _ticket} = Proposals.accept(version.id, user.id)

      assert {:error, :already_decided} = Proposals.accept(version.id, user.id)
      assert {:error, :already_decided} = Proposals.decline(version.id, user.id)
    end

    test "refuses a version that is not a proposal, and one that is not there" do
      user = user_fixture()
      version = version_fixture()

      assert {:error, :not_found} = Proposals.accept(version.id, user.id)
      assert {:error, :not_found} = Proposals.accept(Ecto.UUID.generate(), user.id)
    end

    # The stored text is parsed again rather than trusted, because a person may have edited it
    # into something with no title — and admitting a ticket called "" is worse than refusing.
    test "refuses a proposal a person has edited into something unreadable" do
      user = user_fixture()
      project = registered_project()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})

      version = proposal_fixture(%{job: job, content: "no heading at all"})

      assert {:error, {:invalid_proposal, [%ForgeCore.Error{path: "title"}]}} =
               Proposals.accept(version.id, user.id)

      assert Proposals.decision(version.id) == nil
    end
  end

  describe "accepting is one transaction" do
    # The note says "Acceptance and the admission it causes are one transaction". It was two:
    # `Tickets.admit/3` committed, and only then did the decision insert open its own. Any
    # failure of the second left a real ticket — numbered, branched, with a first job queued and
    # money to spend — that no decision points at and no proposal came from, while the proposal
    # stayed open to be accepted again.
    test "a failure recording the decision admits no ticket" do
      project = registered_project()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      version = proposal_fixture(%{job: job})

      before = length(Tickets.list(project))

      # A user id that no row has: the decision insert fails its foreign key, which is the
      # cheapest way to fail the second half after the first half has done its work.
      assert {:error, _reason} = Proposals.accept(version.id, Ecto.UUID.generate())

      assert length(Tickets.list(project)) == before
      assert Proposals.decision(version.id) == nil
      assert [_still_open] = Proposals.open(project.id)
    end

    # The same defect from the other side. `fetch_open/1` is a check-then-act with no lock, so
    # two accepts both pass it; what stops the second from admitting a duplicate is the unique
    # index on the decision rolling its whole transaction back. Serialised here rather than run
    # concurrently — the sandbox owns one connection — but it is the same second call against a
    # state where the first has already committed.
    test "a second accept admits nothing and says why" do
      user = user_fixture()
      project = registered_project()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      version = proposal_fixture(%{job: job})

      {:ok, _ticket} = Proposals.accept(version.id, user.id)
      after_first = length(Tickets.list(project))

      assert {:error, :already_decided} = Proposals.accept(version.id, user.id)
      assert length(Tickets.list(project)) == after_first
    end
  end

  describe "decline/3" do
    # Without the record the next job proposes the same thing, and the one after that. The
    # backlog an agent reads is built from `open/1`, so "not accepted" has to be distinguishable
    # from "not yet decided".
    test "leaves a record, so the same thing is not proposed again" do
      user = user_fixture()
      job = job_fixture()
      version = proposal_fixture(%{job: job})

      assert {:ok, %Decision{decision: :declined, comment: "out of scope"}} =
               Proposals.decline(version.id, user.id, "out of scope")

      assert Proposals.open(job.project_id) == []
      assert Proposals.decision(version.id).ticket_id == nil
    end

    test "writes an event naming what was decided" do
      user = user_fixture()
      job = job_fixture()
      version = proposal_fixture(%{job: job})

      {:ok, _} = Proposals.decline(version.id, user.id, nil)

      assert [event] =
               job.ticket_id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "proposal.declined"))

      assert event.payload["version_id"] == version.id
      assert event.payload["artifact"] == Workflow.proposal_artifact("score-table.md")
    end
  end

  describe "the database's own guard" do
    # The changeset is not the only writer, and an acceptance with no ticket would be a proposal
    # that is neither open nor anything: the work it described would have left the product.
    test "refuses an accepted decision with no ticket" do
      user = user_fixture()
      version = proposal_fixture()

      attrs = %{artifact_version_id: version.id, user_id: user.id, decision: :accepted}

      assert {:error, changeset} =
               %Decision{} |> Decision.changeset(attrs) |> Repo.insert()

      assert "an accepted proposal became a ticket" in errors_on(changeset).ticket_id
    end

    test "refuses a second decision on the same version" do
      user = user_fixture()
      version = proposal_fixture()
      {:ok, _} = Proposals.decline(version.id, user.id, nil)

      attrs = %{artifact_version_id: version.id, user_id: user.id, decision: :declined}

      assert {:error, changeset} = %Decision{} |> Decision.changeset(attrs) |> Repo.insert()
      assert errors_on(changeset).artifact_version_id != []
    end
  end

  describe "put_from_result/4" do
    defp record(job, proposals, invalid \\ %{}) do
      Multi.new()
      |> Proposals.put_from_result(job, proposals, invalid)
      |> Repo.transaction()
    end

    defp proposal(title), do: Proposal.parse!("# #{title}\n\nWhy it matters.")

    test "stores each proposal under the reserved prefix, scoped to the job that wrote it" do
      job = job_fixture()

      {:ok, _changes} = record(job, %{"score-table.md" => proposal("Extract the score table")})

      assert [artifact] = Artifacts.list_for_job(job.id)
      assert artifact.name == Workflow.proposal_artifact("score-table.md")
      assert artifact.kind == :document

      assert [%{version: version}] = Proposals.open(job.project_id)
      assert version.content == "# Extract the score table\n\nWhy it matters."
      assert version.author == %{"kind" => "job", "id" => job.id}
    end

    # The whole reason `parse: false` is passed, and not the reason it first looks like. This
    # multi is where a job's entire result is recorded, and `put_version/7` without it runs
    # `Document.parse/1`, which refuses a malformed `question` block. A proposal would then take
    # the job's documents, cost, outcome and event down with it.
    #
    # An earlier version of this test asserted `open_questions/1` was empty instead. That
    # passed with `parse: false` removed, because questions are scoped by `ticket_id` and a
    # proposal is scoped to its job — it proved nothing, which is what a mutation is for.
    test "a proposal that is not a valid document never costs the job its result" do
      job = job_fixture()

      body = """
      # Extract the score table

      ```question
      text: a block with no key at all
      ```
      """

      assert {:ok, _changes} = record(job, %{"score-table.md" => Proposal.parse!(body)})
      assert [artifact] = Artifacts.list_for_job(job.id)
      assert artifact.name == Workflow.proposal_artifact("score-table.md")
    end

    test "writes no question rows against the job's artifact" do
      job = job_fixture()

      body = """
      # Extract the score table

      ```question
      key: where
      text: Which module?
      options: [a, b]
      blocking: true
      ```
      """

      {:ok, _changes} = record(job, %{"score-table.md" => Proposal.parse!(body)})

      assert [%{version: version}] = Proposals.open(job.project_id)

      assert Repo.all(
               from q in Forge.Artifacts.Question, where: q.artifact_version_id == ^version.id
             ) == []
    end

    test "refuses what is over the cap, loudly, and keeps the rest" do
      job = job_fixture()
      cap = Proposals.cap()

      proposals =
        Map.new(1..(cap + 2), fn n ->
          {"p#{String.pad_leading(to_string(n), 2, "0")}.md", proposal("Proposal #{n}")}
        end)

      {:ok, _changes} = record(job, proposals)

      assert length(Artifacts.list_for_job(job.id)) == cap

      assert [event] =
               job.ticket_id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "proposal.refused"))

      assert event.payload["cap"] == cap
      assert length(event.payload["files"]) == 2
    end

    test "keeps an unreadable proposal verbatim, and records why it could not be used" do
      job = job_fixture()
      raw = "no heading at all, just prose\n"

      {:ok, _changes} =
        record(job, %{}, %{
          "half.md" => %{"reason" => "title: must begin with a heading", "raw" => raw}
        })

      assert [event] =
               job.ticket_id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "proposal.unreadable"))

      assert event.payload["reasons"]["half.md"] =~ "must begin with a heading"

      # The half that was missing: the reason was recorded and the text the agent wrote was
      # dropped, so nothing showed a person what had actually been proposed.
      assert [%{version: version}] = Proposals.open(job.project_id)
      assert version.content == raw
    end

    # A symlink, a directory, a file that would not open: there is no text to keep, so the
    # reason in the log is all there ever was, and no version is written for it.
    test "an unreadable proposal with no text to keep writes no version" do
      job = job_fixture()

      {:ok, _changes} =
        record(job, %{}, %{
          "leak.md" => %{
            "reason" => "a proposal must be a regular file, got symlink",
            "raw" => nil
          }
        })

      assert Proposals.open(job.project_id) == []
      assert Artifacts.list_for_job(job.id) == []
    end

    # An unreadable proposal is open, so a person can see it — and unacceptable, because
    # `accept/3` parses the stored text rather than trusting it. Declining is what closes it.
    test "an unreadable proposal can be declined but never accepted" do
      user = user_fixture()
      job = job_fixture()

      {:ok, _changes} =
        record(job, %{}, %{"half.md" => %{"reason" => "no heading", "raw" => "prose\n"}})

      assert [%{version: version}] = Proposals.open(job.project_id)
      assert {:error, {:invalid_proposal, _errors}} = Proposals.accept(version.id, user.id)
      assert {:ok, _decision} = Proposals.decline(version.id, user.id, "not usable")
      assert Proposals.open(job.project_id) == []
    end

    test "a job that proposed nothing writes nothing and logs nothing" do
      job = job_fixture()

      {:ok, changes} = record(job, %{})

      assert changes == %{}
      assert Artifacts.list_for_job(job.id) == []
    end
  end

  describe "a filename the platform cannot store" do
    # `artifacts.name` is varchar(255) and the agent picks the filename. An over-long one used
    # to raise Postgrex *out of* `Jobs.record/3` — the transaction holding the job's documents,
    # cost, outcome and event — so the job lost its whole result, and lost it again on every
    # retry because the worker re-sends until acked. § Shape's argument for `parse: false` is
    # that a proposal is not worth a job's outcome; this was the same door one column over.
    test "is refused as unreadable and costs the job nothing" do
      job = job_fixture()
      long = String.duplicate("a", 250) <> ".md"

      assert {:ok, _changes} =
               record(job, %{long => proposal("Too long"), "fine.md" => proposal("Fine")})

      # The well-formed one in the same batch survives, which it did not when this raised.
      assert [artifact] = Artifacts.list_for_job(job.id)
      assert artifact.name == Workflow.proposal_artifact("fine.md")
    end

    # varchar counts characters and a filesystem counts bytes. A 255-byte multibyte name fits
    # the column and then makes `Dir.prepare/3` raise ENAMETOOLONG on every later job start for
    # the project — a self-perpetuating outage nobody can clear, because the proposal stays open.
    test "is refused by bytes, not by characters" do
      job = job_fixture()
      wide = String.duplicate("\u{1D51E}", 62) <> ".md"

      assert String.length(wide) < 255
      assert byte_size(wide) > 248

      {:ok, _changes} = record(job, %{wide => proposal("Wide")})

      assert Artifacts.list_for_job(job.id) == []
    end

    test "says so in the event, rather than dropping it in silence" do
      job = job_fixture()
      long = String.duplicate("a", 250) <> ".md"

      {:ok, _changes} = record(job, %{long => proposal("Too long")})

      assert [event] =
               job.ticket_id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "proposal.unreadable"))

      assert event.payload["reasons"][long] =~ "too long"
    end
  end

  describe "recording the same proposal twice" do
    # A conversation reports its proposals every turn and `out/proposals/` accumulates, so turn
    # five re-reports what turn one wrote; a resumed workflow job does the same. Writing those
    # again as new versions would reopen a proposal the operator had already decided, because a
    # decision attaches to a version and the newest one would have none.
    test "stores it once, so a decided proposal does not come back" do
      user = user_fixture()
      job = job_fixture()
      same = %{"score-table.md" => proposal("Extract the score table")}

      {:ok, _} = record(job, same)
      assert [%{version: version}] = Proposals.open(job.project_id)

      {:ok, _} = Proposals.decline(version.id, user.id, "no")
      {:ok, _} = record(job, same)

      assert Proposals.open(job.project_id) == []

      assert Repo.aggregate(
               from(v in Forge.Artifacts.Version, where: v.artifact_id == ^version.artifact_id),
               :count
             ) == 1
    end

    test "stores a new version when the agent changed what it wrote" do
      job = job_fixture()

      {:ok, _} = record(job, %{"score-table.md" => proposal("First thought")})
      {:ok, _} = record(job, %{"score-table.md" => proposal("Second thought")})

      assert [%{version: version}] = Proposals.open(job.project_id)
      assert version.version == 2
      assert version.content =~ "Second thought"
    end

    # The interaction neither of the two cases beside this one reaches: a revision is in `fresh`
    # like an addition, so a budget of zero refused it and the agent was told its improvement
    # was over a cap it was not over. § Deciding says a changed proposal "does get a new
    # version, which is the case this must not also swallow".
    test "at the cap, revising a proposal is still stored" do
      job = job_fixture()
      cap = Proposals.cap()

      for n <- 1..cap do
        {:ok, _} = record(job, %{"p#{n}.md" => proposal("Proposal #{n}")})
      end

      {:ok, _} = record(job, %{"p1.md" => proposal("Proposal 1, said better")})

      assert [%{version: version}] =
               Proposals.open(job.project_id)
               |> Enum.filter(&(&1.artifact.name == Workflow.proposal_artifact("p1.md")))

      assert version.version == 2
      assert version.content =~ "said better"

      # And it is not reported as refused, which is what the agent would otherwise be told.
      refused =
        job.ticket_id |> Events.for_ticket() |> Enum.filter(&(&1.type == "proposal.refused"))

      assert refused == []
    end

    # The cap is on the job, not on the call. A conversation that could add five more every turn
    # would have no cap at all.
    test "counts what is already stored against the cap" do
      job = job_fixture()
      cap = Proposals.cap()

      for n <- 1..cap do
        {:ok, _} = record(job, %{"p#{n}.md" => proposal("Proposal #{n}")})
      end

      assert length(Artifacts.list_for_job(job.id)) == cap

      {:ok, _} = record(job, %{"one-too-many.md" => proposal("One too many")})

      assert length(Artifacts.list_for_job(job.id)) == cap
    end
  end

  describe "a job's result" do
    # The seam, and it was the one thing nothing held. `put_from_result/4` is covered in every
    # direction above, but only by this file calling it; the line in `Jobs.record/3` that calls
    # it could be deleted and the entire platform suite stayed green — the feature's primary
    # path, undefended. The test that was here was named for both halves and exercised one.
    test "a finished job's proposals are recorded" do
      ticket = ticket_fixture()
      job = job_fixture(%{ticket: ticket, status: :running})

      finished = %ForgeCore.Job.Result{
        status: :finished,
        outcome: :converged,
        declared_outcome: "done",
        proposals: %{"score-table.md" => proposal("Extract the score table")},
        harness: %{}
      }

      {:ok, _job} = Jobs.complete(job.id, finished)

      assert [artifact] = Artifacts.list_for_job(job.id)
      assert artifact.name == Workflow.proposal_artifact("score-table.md")
      assert [%{version: version}] = Proposals.open(job.project_id)
      assert version.content =~ "Extract the score table"
    end

    # And a job that could not read one still says so through the same seam, rather than the
    # reason ending at the worker.
    test "a finished job's unreadable proposal is recorded as unreadable" do
      ticket = ticket_fixture()
      job = job_fixture(%{ticket: ticket, status: :running})

      finished = %ForgeCore.Job.Result{
        status: :finished,
        outcome: :converged,
        declared_outcome: "done",
        invalid_proposals: %{
          "half.md" => %{"reason" => "title: must begin with a level-one heading", "raw" => "x\n"}
        },
        harness: %{}
      }

      {:ok, _job} = Jobs.complete(job.id, finished)

      assert [event] =
               ticket.id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "proposal.unreadable"))

      assert event.payload["reasons"]["half.md"] =~ "level-one heading"
    end

    test "a waiting job's are not, because it will report them again when it resumes" do
      ticket = ticket_fixture()
      job = job_fixture(%{ticket: ticket, status: :running})

      waiting = %ForgeCore.Job.Result{
        status: :waiting,
        proposals: %{"score-table.md" => proposal("Extract the score table")},
        harness: %{}
      }

      {:ok, _job} = Jobs.complete(job.id, waiting)
      assert Artifacts.list_for_job(job.id) == []
    end
  end
end
