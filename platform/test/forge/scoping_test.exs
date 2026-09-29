defmodule Forge.ScopingTest do
  @moduledoc """
  What a non-member cannot do, and cannot see.

  The mutations these are aimed at are the guards themselves: remove the `allow/3` clause from
  an operation, or the `where` from a scoped read, and one of these has to go red. Reads get
  more attention than writes here on purpose — a refused mutation is loud, and a list with one
  extra project in it looks exactly like a working list.
  See `docs/design/identity.md` § Read scoping is the half that leaks.
  """

  use Forge.DataCase, async: true

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.{Artifacts, Operator, Projects, Queue, Tickets}

  setup do
    project = project_fixture()
    ticket = ticket_fixture(%{project: project})

    %{
      project: project,
      ticket: ticket,
      member: member_fixture(project, :member),
      # A member of somewhere *else*. An account with no membership at all cannot tell a project
      # filter from its absence: an inner join on memberships excludes it either way, so the
      # whole suite was blind to `Projects.role/2` losing its project half.
      outsider: member_fixture(project_fixture(), :admin)
    }
  end

  describe "Forge.Operator refuses a non-member" do
    test "edit", %{ticket: ticket, outsider: outsider, member: member} do
      assert {:error, :forbidden} = Operator.edit(ticket, outsider, "plan.md", "theirs")

      # The same call from a member works, so the refusal is about membership and not about the
      # document, the ticket or the arguments.
      assert {:ok, _ticket} = Operator.edit(ticket, member, "plan.md", "mine")
    end

    test "transition", %{ticket: ticket, outsider: outsider} do
      assert {:error, :forbidden} = Operator.transition(ticket, outsider, "planning")
    end

    test "retry", %{ticket: ticket, outsider: outsider, member: member} do
      assert {:error, :forbidden} = Operator.retry(ticket, outsider)
      refute Operator.retry(ticket, member) == {:error, :forbidden}
    end

    test "decide", %{ticket: ticket, outsider: outsider} do
      assert {:error, :forbidden} = Operator.decide(ticket, outsider, :approved, nil)
    end

    test "answer", %{ticket: ticket, outsider: outsider} do
      assert {:error, :forbidden} = Operator.answer(ticket, outsider, "any", %{choice: "a"})
    end

    # Without the guard these answer `:stale` — no version, no reply — so the refusal is told
    # apart from the argument that would also have failed.
    test "answer_all", %{ticket: ticket, outsider: outsider} do
      assert {:error, :forbidden} =
               Operator.answer_all(ticket, outsider, Ecto.UUID.generate(), %{
                 "any" => %{choice: "a", text: nil}
               })
    end

    test "answer_chat", %{project: project, outsider: outsider} do
      chat = chat_fixture(%{project: project})

      assert {:error, :forbidden} =
               Operator.answer_chat(chat, outsider, "any", %{"any" => %{choice: "a", text: nil}})
    end

    test "nothing the outsider did was written", %{ticket: ticket, outsider: outsider} do
      Operator.edit(ticket, outsider, "plan.md", "theirs")

      # The guard has to refuse before the write, not after it. A check that ran on the way out
      # would leave the version behind and only hide it.
      assert Artifacts.versions(ticket.id, "plan.md") == []
    end
  end

  describe "reads are scoped to membership" do
    test "the queue shows only the reader's projects", %{ticket: ticket, member: member} do
      stick(ticket)

      other = project_fixture()
      other_ticket = ticket_fixture(%{project: other})
      stick(other_ticket)

      ids = member |> Queue.items() |> Enum.map(& &1.ticket.id)

      assert ticket.id in ids
      refute other_ticket.id in ids
    end

    test "the unscoped queue still sees everything", %{ticket: ticket} do
      stick(ticket)
      other_ticket = ticket_fixture()
      stick(other_ticket)

      ids = Queue.items() |> Enum.map(& &1.ticket.id)

      # `items/0` is the node-wide read. It is not dead code — it is what makes the scoped one
      # visibly different — but nothing an operator touches may call it.
      assert ticket.id in ids
      assert other_ticket.id in ids
    end

    test "a finished ticket is not in the queue", %{ticket: ticket, member: member} do
      stick(ticket)
      assert ticket.id in Enum.map(Queue.items(member), & &1.ticket.id)

      {:ok, _done} =
        Repo.update(
          Forge.Tickets.Ticket.progress_changeset(ticket, %{
            state: ticket.state,
            status: :done,
            cost_usd: ticket.cost_usd
          })
        )

      # The queue is what will not move until a person acts. A done ticket has moved.
      refute ticket.id in Enum.map(Queue.items(member), & &1.ticket.id)
    end

    test "an outsider's queue is empty", %{ticket: ticket, outsider: outsider} do
      stick(ticket)

      assert Queue.items(outsider) == []
    end

    test "project lists exclude other people's projects", %{project: project, outsider: outsider} do
      # The outsider has a project of their own, so "empty" is not the assertion — "not this
      # one, and still their own" is. An empty list would pass a filter that returned nothing.
      ids = Enum.map(Projects.list(outsider), & &1.id)

      refute project.id in ids
      assert ids != []
    end
  end

  describe "the guards a review found untested" do
    test "an outsider cannot accept a proposal, which would admit a ticket", %{
      project: project,
      outsider: outsider
    } do
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      version = proposal_fixture(%{job: job})

      # Accepting admits a ticket into the project. `allow_proposal/2` answers :not_found rather
      # than :forbidden, so the refusal does not confirm the proposal exists.
      assert {:error, :not_found} = Operator.accept_proposal(version.id, outsider)
      assert Forge.Proposals.open(project.id) != []
    end

    test "an outsider cannot decline one either", %{project: project, outsider: outsider} do
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      version = proposal_fixture(%{job: job})

      assert {:error, :not_found} = Operator.decline_proposal(version.id, outsider)
      assert Forge.Proposals.open(project.id) != []
    end

    test "a member can decline one", %{project: project, member: member} do
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      version = proposal_fixture(%{job: job})

      assert {:ok, _decision} = Operator.decline_proposal(version.id, member)
      assert Forge.Proposals.open(project.id) == []
    end

    test "an outsider cannot remove a member", %{project: project, outsider: outsider} do
      victim = member_fixture(project, :member)

      # `remove_member/3` carries its own copy of the check; only `put_member/4`'s was tested.
      assert {:error, :forbidden} = Projects.remove_member(project, victim, outsider)
      assert Projects.member?(project, victim)
    end

    test "events reach their project through a job when there is no ticket", %{
      project: project,
      member: member
    } do
      chat = chat_fixture(%{project: project})
      {:ok, _event} = Forge.Events.append("chat.opened", {:user, member.id}, %{job_id: chat.id})

      # A conversation has no ticket, so the job branch of the derivation is the only thing that
      # can attribute its events — and an event with no project has no visibility to decide.
      assert Enum.any?(
               Forge.Events.for_project(project.id, 50),
               &(&1.job_id == chat.id and &1.project_id == project.id)
             )
    end
  end

  describe "proposals are counted per reader" do
    test "open_count/1 counts only the reader's projects", %{project: project, member: member} do
      mine = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      proposal_fixture(%{job: mine})

      other = project_fixture()
      proposal_fixture(%{job: job_fixture(%{ticket: ticket_fixture(%{project: other})})})

      # The node-wide count sees both; the reader's count sees one. The digest is built from the
      # second, so a leak here is a number telling you about work you cannot open.
      assert Forge.Proposals.open_count() >= 2
      assert Forge.Proposals.open_count(member) == 1
    end
  end

  describe "the event log carries its project" do
    test "an event written against a ticket is attributed to that ticket's project", %{
      ticket: ticket,
      project: project,
      member: member
    } do
      {:ok, _ticket} = Operator.edit(ticket, member, "plan.md", "text")

      events = Forge.Events.for_project(project.id, 50)

      # The mutation this catches: dropping the derivation in `Events.log/5`. Without it these
      # rows have a null project and the project page goes quiet.
      assert events != []
      assert Enum.all?(events, &(&1.project_id == project.id))
    end

    test "another project's events are not in it", %{project: project, member: member} do
      other = project_fixture()
      other_ticket = ticket_fixture(%{project: other})
      {:ok, _t} = Operator.edit(other_ticket, member_fixture(other, :member), "plan.md", "x")

      ours = Tickets.list(project)
      assert ours != []

      ids = project.id |> Forge.Events.for_project(50) |> Enum.map(& &1.project_id) |> Enum.uniq()

      refute other.id in ids
      assert member
    end
  end

  defp stick(ticket) do
    {:ok, ticket} =
      Repo.update(
        Forge.Tickets.Ticket.progress_changeset(ticket, %{
          state: ticket.state,
          status: :stuck,
          cost_usd: ticket.cost_usd
        })
      )

    ticket
  end
end
