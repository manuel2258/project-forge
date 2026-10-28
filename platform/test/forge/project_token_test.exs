defmodule Forge.ProjectTokenTest do
  @moduledoc """
  The project token below the web layer: what may be issued, what each access reaches, who it
  acts as, and that no guard rests on a single check.
  `docs/design/git-hosting.md` § One project token, two doors.
  """

  use Forge.DataCase, async: true

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Access, Actor, Events, Operator, Proposals, Repo, Tickets}
  alias Forge.Accounts.Scope
  alias Forge.Git.{Token, Tokens}

  defp project! do
    {:ok, project} =
      register_owned!(%{
        name: "pt-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    project
  end

  defp issue!(project, opts \\ []) do
    {:ok, secret, token} =
      Tokens.issue(project, Keyword.merge([name: "ci", git: :reader, api: :read], opts))

    {secret, token}
  end

  describe "what may be issued" do
    test "a hand-minted token needs a name of at most sixty characters" do
      project = project!()

      assert {:error, cs} = Tokens.issue(project, git: :reader)
      assert %{name: _} = Map.new(cs.errors)

      assert {:error, cs} = Tokens.issue(project, name: String.duplicate("n", 61), git: :reader)
      assert %{name: _} = Map.new(cs.errors)

      assert {:ok, _secret, _token} =
               Tokens.issue(project, name: String.duplicate("n", 60), git: :reader)
    end

    test "a token that allows nothing is refused with a reason" do
      assert {:error, cs} = Tokens.issue(project!(), name: "x", git: :none, api: :none)
      assert {"allows nothing: choose git access, API access or both", _} = cs.errors[:git_access]
    end

    test "minutes are a job's: a person's token cannot be longer, or shorter, than days allow" do
      project = project!()
      year = 365 * 24 * 60

      assert {:ok, _secret, token} =
               Tokens.issue(project, name: "x", git: :reader, ttl_minutes: year)

      assert_in_delta DateTime.diff(token.expires_at, DateTime.utc_now()), year * 60, 5

      for minutes <- [year + 1, 100_000_000, 0, -5] do
        assert {:error, {:bad_days, 365}} =
                 Tokens.issue(project, name: "x", git: :reader, ttl_minutes: minutes)
      end

      assert {:error, {:bad_days, 365}} =
               Tokens.issue(project, name: "x", git: :reader, ttl_minutes: 5, days: 5)

      # A job's is the engine's and is not held to a year.
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})

      assert {:ok, _secret, _token} =
               Tokens.issue(project, job_id: job.id, git: :reader, ttl_minutes: year + 60)
    end

    test "the lifetime is days, from one to a year, and never open" do
      project = project!()
      issue = &Tokens.issue(project, name: "x", git: :reader, days: &1)

      assert {:error, {:bad_days, 365}} = issue.(0)
      assert {:error, {:bad_days, 365}} = issue.(366)
      assert {:error, {:bad_days, 365}} = issue.(-1)
      assert {:ok, _secret, t1} = issue.(1)
      assert {:ok, _secret, t365} = issue.(365)

      assert_in_delta DateTime.diff(t1.expires_at, DateTime.utc_now()), 86_400, 5
      assert_in_delta DateTime.diff(t365.expires_at, DateTime.utc_now()), 365 * 86_400, 5
    end

    test "only a branch token names a ref, and a branch token must" do
      project = project!()
      assert {:error, cs} = Tokens.issue(project, name: "x", git: :branch)
      assert cs.errors[:ref]

      assert {:error, cs} =
               Tokens.issue(project, name: "x", git: :developer, ref: "refs/heads/ticket/1")

      assert cs.errors[:ref]
    end

    test "a job's token is a reader or one branch, and never opens the API" do
      project = project!()
      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket})

      for git <- [:developer, :admin, :none] do
        assert {:error, cs} = Tokens.issue(project, job_id: job.id, git: git)
        assert cs.errors[:git_access]
      end

      assert {:error, cs} = Tokens.issue(project, job_id: job.id, git: :reader, api: :write)
      assert cs.errors[:api_access]
      assert {:ok, _secret, _token} = Tokens.issue(project, job_id: job.id, git: :reader)
    end

    test "a job's token is issued reader or branch, and no API" do
      project = project!()
      ticket = ticket_fixture(%{project: project})
      agent = job_fixture(%{ticket: ticket})
      {:ok, _secret, token} = Tokens.issue_for_job(agent, ticket, project)
      assert %{git_access: :branch, api_access: :none} = token
    end
  end

  describe "allowed_refs/2" do
    test "branch, developer and admin each reach exactly their own" do
      project = project!()
      open = ticket_fixture(%{project: project, number: 1, branch: "ticket/1"})
      stuck = ticket_fixture(%{project: project, number: 2, branch: "ticket/2"})
      done = ticket_fixture(%{project: project, number: 3, branch: "ticket/3"})
      cancelled = ticket_fixture(%{project: project, number: 4, branch: "ticket/4"})
      Repo.update!(Ecto.Changeset.change(stuck, status: :stuck))
      Repo.update!(Ecto.Changeset.change(done, status: :done))
      Repo.update!(Ecto.Changeset.change(cancelled, status: :cancelled))

      {_, reader} = issue!(project, git: :reader)
      {_, none} = issue!(project, git: :none)
      {_, branch} = issue!(project, git: :branch, ref: "refs/heads/ticket/3")
      {_, developer} = issue!(project, git: :developer)
      {_, admin} = issue!(project, git: :admin)

      assert Tokens.allowed_refs(reader, project) == []
      assert Tokens.allowed_refs(none, project) == []
      assert Tokens.allowed_refs(branch, project) == ["refs/heads/ticket/3"]

      assert Tokens.allowed_refs(developer, project) == [
               "refs/heads/ticket/1",
               "refs/heads/ticket/2"
             ]

      assert Tokens.allowed_refs(admin, project) ==
               ["refs/heads/ticket/1", "refs/heads/ticket/2", "refs/heads/main"]

      assert open.status == :active
    end

    test "another project's tickets are not in the list" do
      project = project!()
      ticket_fixture(%{project: project_fixture(), number: 1, branch: "ticket/1"})
      {_, developer} = issue!(project, git: :developer)
      assert Tokens.allowed_refs(developer, project) == []
    end
  end

  describe "the two doors" do
    test "git access none is still read at the API, and API none still clones" do
      project = project!()
      {api_only, _} = issue!(project, git: :none, api: :read)
      {git_only, _} = issue!(project, git: :reader, api: :none)

      assert :error = Tokens.authorise(api_only, project, :read)
      assert {:ok, _} = Tokens.authenticate_api(api_only)
      assert {:ok, _} = Tokens.authorise(git_only, project, :read)
      assert :error = Tokens.authenticate_api(git_only)
    end

    test "a reader may not write, a developer may" do
      project = project!()
      {reader, _} = issue!(project, git: :reader)
      {developer, _} = issue!(project, git: :developer)

      assert :error = Tokens.authorise(reader, project, :write)
      assert {:ok, _} = Tokens.authorise(developer, project, :write)
    end

    test "revoked and expired are refused at both doors" do
      project = project!()
      {revoked, row} = issue!(project, git: :reader, api: :read)
      {expired, expired_row} = issue!(project, git: :reader, api: :read)
      {:ok, _} = Tokens.revoke(row.id)

      Repo.update!(
        Ecto.Changeset.change(expired_row,
          expires_at: DateTime.add(DateTime.utc_now(:second), -5)
        )
      )

      for secret <- [revoked, expired] do
        assert :error = Tokens.authorise(secret, project, :read)
        assert :error = Tokens.authenticate_api(secret)
      end
    end

    test "a token for one project is nothing at another's git" do
      {secret, _} = issue!(project!(), git: :reader)
      assert :error = Tokens.authorise(secret, project!(), :read)
    end
  end

  describe "sweep/0" do
    test "deletes a job's long-expired token and keeps a person's, which is an audit record" do
      project = project!()
      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket})
      {:ok, _secret, jobs} = Tokens.issue(project, job_id: job.id, git: :reader)
      {_, mine} = issue!(project)
      old = DateTime.add(DateTime.utc_now(:second), -3 * 86_400)
      for t <- [jobs, mine], do: Repo.update!(Ecto.Changeset.change(t, expires_at: old))

      assert Tokens.sweep() >= 1
      refute Repo.get(Token, jobs.id)
      assert Repo.get(Token, mine.id)
    end
  end

  describe "Access for a token scope" do
    test "use only with API write, only on its own project, never manage" do
      project = project!()
      other = project!()
      {_, write} = issue!(project, api: :write)
      {_, read} = issue!(project, api: :read)
      {_, none} = issue!(project, api: :none, git: :reader)

      assert Access.can?(Scope.for_token(write, project), :use)
      refute Access.can?(Scope.for_token(write, project), :manage)
      refute Access.can?(Scope.for_token(write, other), :use)
      refute Access.can?(Scope.for_token(read, project), :use)
      refute Access.can?(Scope.for_token(none, project), :use)
    end

    test "a job's token holds nothing even if forced to write" do
      project = project!()
      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket})
      {:ok, _secret, row} = Tokens.issue(project, job_id: job.id, git: :reader)
      forced = Repo.update!(Ecto.Changeset.change(row, api_access: :write))

      refute Access.can?(Scope.for_token(forced, project), :use)
    end
  end

  describe "Operator with a token" do
    test "issuing records the issuer and logs without the secret; revoking logs too" do
      project = project!()
      admin = member_fixture(project, :admin)

      assert {:ok, secret, token} =
               Operator.issue_token(project, admin,
                 name: "bot",
                 git: :reader,
                 api: :write,
                 days: 3
               )

      assert token.issued_by_id == admin.id

      [issued] = Events.for_project(project.id, 10) |> Enum.filter(&(&1.type == "token.issued"))
      assert issued.payload["token_id"] == token.id
      assert %{"name" => "bot", "git" => "reader", "api" => "write"} = issued.payload
      refute inspect(issued) =~ secret

      assert {:ok, _} = Operator.revoke_token(project, admin, token.id)
      assert Enum.any?(Events.for_project(project.id, 10), &(&1.type == "token.revoked"))
    end

    test "a member cannot issue, and a caller cannot name a job" do
      project = project!()
      member = member_fixture(project, :member)
      admin = member_fixture(project, :admin)

      assert {:error, :forbidden} = Operator.issue_token(project, member, name: "x", git: :reader)

      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})

      assert {:ok, _secret, token} =
               Operator.issue_token(project, admin, name: "x", git: :reader, job_id: job.id)

      assert is_nil(token.job_id)
    end

    test "a read token cannot act, a write token of another project cannot either" do
      project = project!()
      other = project!()
      {:ok, ticket} = Tickets.admit(project, %{title: "T"}, :system)
      {_, read} = issue!(project, api: :read)
      {_, foreign} = issue!(other, api: :write)
      {_, write} = issue!(project, api: :write)

      assert {:error, :forbidden} = Operator.cancel(ticket, read)
      assert {:error, :forbidden} = Operator.cancel(ticket, foreign)
      assert {:ok, %{status: :cancelled}} = Operator.cancel(ticket, write)

      assert {:error, :forbidden} = Operator.admit(project, read, %{title: "x"})
      assert {:error, :forbidden} = Operator.admit(project, foreign, %{title: "x"})
    end

    test "a proposal is accepted or declined as API, and another project's is not found" do
      project = project!()
      other = project!()
      {_, write} = issue!(project, api: :write, name: "triage")
      {_, foreign} = issue!(other, api: :write)
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      accepted = proposal_fixture(%{job: job, file: "a.md", title: "Accept me"})
      declined = proposal_fixture(%{job: job, file: "b.md", title: "Decline me"})

      assert {:error, :not_found} = Operator.accept_proposal(accepted.id, foreign)
      assert {:error, :not_found} = Operator.decline_proposal(declined.id, foreign)

      assert {:ok, ticket} = Operator.accept_proposal(accepted.id, write)
      assert {:ok, decision} = Operator.decline_proposal(declined.id, write)
      assert decision.token_id == write.id and is_nil(decision.user_id)

      assert %{actor: %{"kind" => "api", "name" => "triage"}} =
               ticket.id
               |> Events.for_ticket()
               |> Enum.find(&(&1.type == "ticket.admitted"))

      assert [accepted_decision] =
               Repo.all(Forge.Proposals.Decision) |> Enum.filter(& &1.ticket_id)

      assert accepted_decision.token_id == write.id
      assert Proposals.open(project.id) == []
    end
  end

  describe "the author" do
    test "an api actor is an event and a version author, with the name carried" do
      assert Events.encode_actor({:api, "i", "n"}) == %{
               "kind" => "api",
               "id" => "i",
               "name" => "n"
             }

      assert Actor.of(%Token{id: "i", name: "n"}) == {:api, "i", "n"}
      assert Actor.columns({:api, "i", "n"}) == %{user_id: nil, token_id: "i"}
      assert Actor.columns("u") == %{user_id: "u", token_id: nil}
    end

    test "a changeset refuses a row with two authors or none, before the database does" do
      base = %{
        question_id: Ecto.UUID.generate(),
        artifact_version_id: Ecto.UUID.generate(),
        choice: "a"
      }

      user = Ecto.UUID.generate()
      token = Ecto.UUID.generate()

      refute Forge.Artifacts.Answer.changeset(
               %Forge.Artifacts.Answer{},
               Map.put(base, :user_id, user)
             ).errors[:user_id]

      refute Forge.Artifacts.Answer.changeset(
               %Forge.Artifacts.Answer{},
               Map.put(base, :token_id, token)
             ).errors[:user_id]

      both = Map.merge(base, %{user_id: user, token_id: token})
      assert Forge.Artifacts.Answer.changeset(%Forge.Artifacts.Answer{}, both).errors[:user_id]
      assert Forge.Artifacts.Answer.changeset(%Forge.Artifacts.Answer{}, base).errors[:user_id]
    end

    test "the database refuses a row with two authors or none" do
      project = project!()
      user = user_fixture()
      {_, token} = issue!(project, api: :write)
      ticket = ticket_fixture(%{project: project})

      {:ok, version} =
        Forge.Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{content: "x"})

      row = fn author ->
        Map.merge(
          %{
            id: Ecto.UUID.bingenerate(),
            artifact_version_id: Ecto.UUID.dump!(version.id),
            decision: "approved",
            transition: %{"from" => "a", "to" => "b"},
            inserted_at: DateTime.utc_now(:second)
          },
          author
        )
      end

      dump = &Ecto.UUID.dump!/1

      for author <- [
            %{user_id: dump.(user.id), token_id: dump.(token.id)},
            %{user_id: nil, token_id: nil}
          ] do
        assert_raise Postgrex.Error, ~r/approvals_one_author/, fn ->
          Repo.insert_all("approvals", [row.(author)])
        end
      end
    end

    test "a token that wrote an answer is its author, and cannot be deleted from under it" do
      project = project!()
      {_, token} = issue!(project, api: :write)
      {:ok, ticket} = Tickets.admit(project, %{title: "T"}, :system)

      {:ok, _} =
        Forge.Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
          content:
            "```question\nkey: k\ntext: ok?\noptions: [{label: a, detail: b}]\nblocking: false\nassumption: a\n```\n"
        })

      question = Forge.Artifacts.find_open_question(ticket.id, "k")

      assert {:ok, answer} =
               Forge.Artifacts.answer(question, {:api, token.id, token.name}, %{choice: "a"})

      assert answer.token_id == token.id and is_nil(answer.user_id)

      assert_raise Ecto.ConstraintError, ~r/answers_token_id_fkey/, fn -> Repo.delete(token) end
    end
  end
end
