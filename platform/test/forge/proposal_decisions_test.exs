defmodule Forge.ProposalDecisionsTest do
  @moduledoc """
  Deciding proposals several at a time, and reopening a declined one
  (`docs/design/ticket-proposals.md` § Deciding, `docs/design/ui.md` § Proposals).

  The two rules worth a failing test each: **declining several is refused whole** — one the actor
  may not decline, or one decided meanwhile, and nothing is written — and **reopening is for a
  declined proposal only, by anyone who may decline it**, and writes a new version rather than
  undoing the decline.
  """

  use Forge.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.Events.Event
  alias Forge.Operator
  alias Forge.Proposals
  alias Forge.Proposals.Decision
  alias Forge.Repo

  # A member of a project with a job that wrote three proposals.
  setup do
    user = user_fixture()
    job = job_fixture()
    project = Forge.Projects.get!(job.project_id)
    join!(project, user, :member)

    versions =
      for name <- ~w(one two three),
          do: proposal_fixture(%{job: job, file: "#{name}.md", title: "Proposal #{name}"})

    %{user: user, job: job, project: project, versions: versions}
  end

  defp decided?(version), do: Proposals.decision(version.id) != nil

  describe "declining several" do
    test "declines every one with the one reason", %{user: user, versions: versions} do
      ids = Enum.map(versions, & &1.id)

      assert {:ok, decisions} = Operator.decline_proposals(ids, user, "not this quarter")

      assert length(decisions) == 3
      assert Enum.all?(decisions, &(&1.decision == :declined))
      assert Enum.all?(decisions, &(&1.comment == "not this quarter"))
      assert Enum.all?(versions, &decided?/1)
    end

    # All in one project, so the one-project rule passes them: what refuses them is membership.
    test "a lot in a project the actor is not in is refused and nothing written", %{
      versions: versions
    } do
      stranger = user_fixture()
      ids = Enum.map(versions, & &1.id)

      assert Operator.decline_proposals(ids, stranger, "no") == {:error, :not_found}
      refute Enum.any?(versions, &decided?/1)
    end

    test "one in a project the actor is not in refuses the lot and writes nothing", %{
      user: user,
      versions: versions
    } do
      foreign = proposal_fixture(%{job: job_fixture(), file: "theirs.md"})
      ids = Enum.map(versions, & &1.id) ++ [foreign.id]

      assert Operator.decline_proposals(ids, user, "no") == {:error, :not_found}
      refute Enum.any?([foreign | versions], &decided?/1)
    end

    test "one that does not exist refuses the lot as not found", %{
      user: user,
      versions: versions
    } do
      ids = Enum.map(versions, & &1.id) ++ [Ecto.UUID.generate()]

      assert Operator.decline_proposals(ids, user, "no") == {:error, :not_found}
      refute Enum.any?(versions, &decided?/1)
    end

    test "one the actor could decline, but in another project, refuses the lot too", %{
      user: user,
      versions: versions
    } do
      other = job_fixture()
      join!(Forge.Projects.get!(other.project_id), user, :member)
      elsewhere = proposal_fixture(%{job: other, file: "elsewhere.md"})

      assert Operator.decline_proposals([elsewhere.id | Enum.map(versions, & &1.id)], user, "no") ==
               {:error, :not_found}

      refute Enum.any?([elsewhere | versions], &decided?/1)
    end

    test "one already decided refuses the lot, and nothing else is written", %{
      user: user,
      versions: [a, b, c]
    } do
      {:ok, _decision} = Proposals.decline(b.id, user.id, "first")

      assert Operator.decline_proposals([a.id, b.id, c.id], user, "second") ==
               {:error, :already_decided}

      refute decided?(a)
      refute decided?(c)
    end
  end

  describe "reopening" do
    test "a declined proposal comes back open, as a new version by the person reopening it", %{
      user: user,
      project: project,
      versions: [version | _]
    } do
      {:ok, _decision} = Proposals.decline(version.id, user.id, "needs a server first")

      assert {:ok, reopened} = Operator.reopen_proposal(version.id, user)

      assert reopened.version == version.version + 1
      assert reopened.content == version.content
      assert reopened.author == %{"kind" => "user", "id" => user.id}
      # The decline stays on the version it decided, and the new one is open.
      assert %Decision{decision: :declined, comment: "needs a server first"} =
               Proposals.decision(version.id)

      assert reopened.id in Enum.map(Proposals.open(project.id), & &1.version.id)

      assert [%Event{payload: payload}] =
               Repo.all(from e in Event, where: e.type == "proposal.reopened")

      assert payload["declined_version_id"] == version.id
      assert payload["version_id"] == reopened.id
    end

    test "only a declined one: an open one and an accepted one are refused, nothing written", %{
      user: user,
      job: job,
      versions: [open, accepted | _]
    } do
      ticket = ticket_fixture(%{project: Forge.Projects.get!(job.project_id)})

      Repo.insert!(%Decision{
        artifact_version_id: accepted.id,
        user_id: user.id,
        decision: :accepted,
        ticket_id: ticket.id
      })

      assert Operator.reopen_proposal(open.id, user) == {:error, :not_declined}
      assert Operator.reopen_proposal(accepted.id, user) == {:error, :not_declined}
      assert Repo.all(from e in Event, where: e.type == "proposal.reopened") == []
    end

    test "a declined version something newer followed is not reopened again", %{
      user: user,
      versions: [version | _]
    } do
      {:ok, _decision} = Proposals.decline(version.id, user.id, "no")
      {:ok, _reopened} = Operator.reopen_proposal(version.id, user)

      assert Operator.reopen_proposal(version.id, user) == {:error, :not_declined}
    end

    test "someone who may not decline it may not reopen it, and is told it does not exist", %{
      user: user,
      versions: [version | _]
    } do
      {:ok, _decision} = Proposals.decline(version.id, user.id, "no")
      stranger = user_fixture()

      assert Operator.reopen_proposal(version.id, stranger) == {:error, :not_found}
      assert Repo.all(from e in Event, where: e.type == "proposal.reopened") == []
    end
  end

  describe "decided/1" do
    test "lists each decision and says which are no longer the latest", %{
      user: user,
      project: project,
      versions: [a, b | _]
    } do
      {:ok, _} = Proposals.decline(a.id, user.id, "no")
      {:ok, _} = Proposals.decline(b.id, user.id, "also no")
      {:ok, _} = Operator.reopen_proposal(a.id, user)

      decided = Proposals.decided(project.id)

      assert Enum.map(decided, & &1.version.id) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert Enum.find(decided, &(&1.version.id == a.id)).latest == false
      assert Enum.find(decided, &(&1.version.id == b.id)).latest == true
      assert Proposals.decided(project_fixture().id) == []
    end
  end
end
