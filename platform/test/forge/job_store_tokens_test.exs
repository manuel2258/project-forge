defmodule Forge.JobStoreTokensTest do
  @moduledoc """
  A store token minted for a job stops working when the job ends (`docs/design/storage.md`
  § Serving): every one the platform hands a job — the transcript and session `put`s, a group's
  prefix, the `get`s for its inputs, history and attachments — names the job it was handed to, and
  is refused as an expired one is once the platform has recorded the job as ended.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Engine, FakeWorker, Jobs, Repo, Tickets}
  alias Forge.Jobs.Job
  alias Forge.Storage.Token

  @workflow """
  version: 1
  initial: implementing
  states:
    implementing:
      prompt: agents/implement.md
      inputs: [ticket]
      produces: [implementation.md, pack/*]
      budget: { turns: 150, tokens: 12M }
    review_ready: {}
  transitions:
    - { from: implementing, to: review_ready }
  limits:
    ticket_tokens: 100M
  """

  @salt "forge storage"

  setup do
    repo = seeded_repo(%{".forge/workflow.yml" => @workflow})

    {:ok, project} =
      register_owned!(%{name: "tokens-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, {:user, user.id})
    worker = FakeWorker.connect()

    %{ticket: ticket, user: user, project: project, worker: worker}
  end

  defp pending(ticket) do
    [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.status == :pending))
    job
  end

  # What a token says, without the store's opinion of it: `{op, key_or_prefix, job}`.
  defp claims(token) do
    [_protected, payload, _signature] = String.split(token, ".")

    {data, _signed_at_ms, _seconds} =
      payload |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term([:safe])

    data
  end

  # Every store token in an assignment, whatever it is for: a string under a key called `token`
  # or ending in `_token`, outside the git endpoint's (which is a different credential, checked by
  # the git host) — found by walking the payload rather than by naming the places, so a mint site
  # that is added without `job:` is found too.
  defp store_tokens(%{} = map, path) do
    Enum.flat_map(map, fn
      {"git", _git} ->
        []

      {"credential", _credential} ->
        []

      {key, value} when is_binary(value) ->
        if token_key?(key) and signed?(value), do: [{path ++ [key], value}], else: []

      {key, value} ->
        store_tokens(value, path ++ [key])
    end)
  end

  defp store_tokens(list, path) when is_list(list),
    do:
      list
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, i} -> store_tokens(item, path ++ [i]) end)

  defp store_tokens(_other, _path), do: []

  defp token_key?(key), do: key == "token" or String.ends_with?(key, "_token")

  # A store token has the three dot-separated parts of a `Phoenix.Token`; a git secret and a
  # sealed credential do not.
  defp signed?(value),
    do: match?([_, _, _], String.split(value, ".")) and match?(%{op: _}, safe_claims(value))

  defp safe_claims(token) do
    claims(token)
  rescue
    _not_a_token -> nil
  end

  defp key_of(%{key: key}), do: key
  defp key_of(%{prefix: prefix}), do: prefix <> "file"

  defp verifies(token) do
    %{op: op} = data = claims(token)
    Token.verify(token, op, key_of(data))
  end

  defp finish!(job_id, attrs) do
    job_id
    |> Jobs.get!()
    |> Job.progress_changeset(Map.merge(%{status: :finished, outcome: :converged}, attrs))
    |> Repo.update!()
  end

  describe "an agent job's tokens" do
    test "every one names the job and works while it runs, and none after it has ended",
         context do
      %{ticket: ticket, worker: worker, project: project} = context
      job = pending(ticket)

      # A project with a seed, which is fetched with a token of its own (`docs/design/storage.md`).
      project |> Ecto.Changeset.change(seed_id: "seed-1") |> Repo.update!()
      assignment = FakeWorker.assign(job, worker)

      tokens = store_tokens(assignment, [])
      paths = Enum.map(tokens, &elem(&1, 0))

      # The ones a run with a group of files has: the transcript, the session, the prefix, the seed
      # (when the project has one).
      assert ["store", "transcript_token"] in paths
      assert ["store", "session_token"] in paths
      assert ["outputs", "token"] in paths
      assert ["seed", "token"] in paths

      for {path, token} <- tokens do
        assert claims(token).job == job.id, "#{inspect(path)} does not name its job"
        assert verifies(token) == :ok, "#{inspect(path)} did not work while the job ran"
      end

      finish!(job.id, %{})

      for {path, token} <- tokens do
        assert verifies(token) == {:error, :expired}, "#{inspect(path)} outlived its job"
      end
    end

    test "a job that waits on a question has not ended", context do
      %{ticket: ticket, worker: worker} = context
      job = pending(ticket)
      assignment = FakeWorker.assign(job, worker)
      tokens = store_tokens(assignment, [])

      job
      |> then(&Job.progress_changeset(Jobs.get!(&1.id), %{status: :waiting}))
      |> Repo.update!()

      assert Enum.all?(tokens, fn {_path, token} -> verifies(token) == :ok end)

      for status <- [:parked, :hibernated] do
        job
        |> then(&Job.progress_changeset(Jobs.get!(&1.id), %{status: status}))
        |> Repo.update!()

        assert Enum.all?(tokens, fn {_path, token} -> verifies(token) == :ok end)
      end
    end

    test "a failed job's tokens have ended too", context do
      %{ticket: ticket, worker: worker} = context
      job = pending(ticket)
      tokens = store_tokens(FakeWorker.assign(job, worker), [])

      finish!(job.id, %{outcome: :error})
      assert Enum.all?(tokens, fn {_path, token} -> verifies(token) == {:error, :expired} end)
    end

    test "a resumed run's session `get` names the job it is handed to", context do
      %{ticket: ticket, worker: worker} = context
      job = pending(ticket)
      first = FakeWorker.assign(job, worker)

      # The job left a session; a requeue and a new assignment hand it back.
      Job.progress_changeset(Jobs.get!(job.id), %{
        harness_session_id: "sess-1",
        session_blob: %{
          "key" => first["store"]["session_prefix"] <> "1.jsonl",
          "version" => "2.1.1"
        }
      })
      |> Repo.update!()

      {:ok, _} = Jobs.requeue(job.id, :worker_lost)
      second = FakeWorker.assign(Jobs.get!(job.id), worker)

      assert {["session", "token"], token} =
               second |> store_tokens([]) |> Enum.find(&(elem(&1, 0) == ["session", "token"]))

      assert %{op: :get, job: job_id} = claims(token)
      assert job_id == job.id
    end

    test "a forked session read belongs to the job that reads it, not the one that wrote it",
         context do
      %{ticket: ticket, worker: worker} = context
      old = pending(ticket)

      # The earlier attempt's session, which the new attempt forks: the token must outlive the
      # earlier job, which is finished.
      Job.progress_changeset(old, %{
        status: :finished,
        outcome: :budget_exhausted,
        exhausted: :tokens,
        harness_session_id: "sess-old",
        session_blob: %{"key" => "job/#{old.id}/session-x/1.jsonl", "version" => "2.1.1"}
      })
      |> Repo.update!()

      {:ok, fresh} =
        Repo.insert(
          Job.create_changeset(%Job{}, %{
            kind: :workflow,
            ticket_id: ticket.id,
            project_id: ticket.project_id,
            state: old.state,
            attempt: 2,
            spec: old.spec,
            resume_from_id: old.id,
            memory_max: old.memory_max,
            cores: old.cores
          })
        )

      assignment = FakeWorker.assign(fresh, worker)

      assert %{"session" => %{"token" => token, "key" => key}} = assignment
      assert key == "job/#{old.id}/session-x/1.jsonl"
      assert claims(token).job == fresh.id
      assert verifies(token) == :ok
    end
  end

  describe "an attachment's token" do
    test "names the job it is handed to and ends with it", context do
      %{ticket: ticket, worker: worker} = context
      job = pending(ticket)
      FakeWorker.assign(job, worker)

      files = [
        %{
          file: "shot.png",
          version_id: Ecto.UUID.generate(),
          key: "attachments/a/1",
          size: 3,
          hash: "h"
        }
      ]

      assert [%{"token" => token, "key" => "attachments/a/1"}] =
               Forge.Attachments.deliveries(files, job.id, 0)

      assert claims(token).job == job.id
      assert Token.verify(token, :get, "attachments/a/1") == :ok

      finish!(job.id, %{})
      assert Token.verify(token, :get, "attachments/a/1") == {:error, :expired}
    end
  end

  describe "a cancelled job" do
    test "keeps its tokens for the store's ordinary lifetime, so its last uploads arrive",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      job = pending(ticket)
      tokens = store_tokens(FakeWorker.assign(job, worker), [])

      {:ok, _} = Engine.cancel(ticket, user.id)
      assert %Job{status: :finished, outcome: :cancelled} = Jobs.get!(job.id)

      # The worker kills the harness, uploads, and only then reports.
      assert Enum.all?(tokens, fn {_path, token} -> verifies(token) == :ok end)
    end

    test "and not longer than it", context do
      %{ticket: ticket, user: user, worker: worker} = context
      job = pending(ticket)
      tokens = store_tokens(FakeWorker.assign(job, worker), [])
      {:ok, _} = Engine.cancel(ticket, user.id)

      # The grace is the store's own lifetime: with none, the job's end is the tokens'.
      store = Application.get_env(:forge, Forge.Storage, [])
      Application.put_env(:forge, Forge.Storage, Keyword.put(store, :token_max_age, 0))
      on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

      assert Enum.all?(tokens, fn {_path, token} -> verifies(token) == {:error, :expired} end)
    end
  end

  describe "a conversation's tokens" do
    test "name it and end with it", %{project: project, worker: worker} do
      chat = chat_fixture(%{project: project})
      assignment = FakeWorker.assign(chat, worker)

      tokens = store_tokens(assignment, [])
      assert ["store", "transcript_token"] in Enum.map(tokens, &elem(&1, 0))
      assert ["outputs", "token"] in Enum.map(tokens, &elem(&1, 0))

      for {_path, token} <- tokens do
        assert claims(token).job == chat.id
        assert verifies(token) == :ok
      end

      finish!(chat.id, %{outcome: nil})
      assert Enum.all?(tokens, fn {_path, token} -> verifies(token) == {:error, :expired} end)
    end
  end

  describe "a token with no job" do
    test "is its lifetime alone, as a new worker's seed token is" do
      token = Token.sign(:get, "seed/x")
      refute Map.has_key?(claims(token), :job)
      assert Token.verify(token, :get, "seed/x") == :ok
    end

    test "naming a job that does not exist is naming one that has ended" do
      token = Token.sign(:get, "job/x/y", job: Ecto.UUID.generate())
      assert Token.verify(token, :get, "job/x/y") == {:error, :expired}
    end

    test "the key is still checked before the job: the wrong key is the wrong key" do
      token = Token.sign(:get, "job/x/y", job: Ecto.UUID.generate())
      assert Token.verify(token, :get, "job/x/z") == {:error, :wrong_key}
      assert Token.verify(token, :put, "job/x/y") == {:error, :wrong_key}
    end

    test "is the same word an expired token is refused with" do
      assert {:ok, _} = Phoenix.Token.verify(ForgeWeb.Endpoint, @salt, Token.sign(:get, "k"))
    end
  end

  describe "at a thousand hours" do
    test "no token lapses before the job, and the git token's expiry is a date", context do
      %{ticket: ticket, worker: worker, project: project} = context
      job = pending(ticket)
      spec = update_in(job.spec, ["budget"], &Map.put(&1, "timeout_ms", 3_600_000_000))
      {1, _} = Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [spec: spec])

      assignment = FakeWorker.assign(Jobs.get!(job.id), worker)
      assert assignment["wall_clock_ms"] == 3_600_000_000

      thousand_hours = 1_000 * 3_600

      assert store_token_lifetime(assignment["store"]["transcript_token"]) > thousand_hours
      assert store_token_lifetime(assignment["store"]["session_token"]) > thousand_hours

      token = Repo.get_by!(Forge.Git.Token, job_id: job.id)
      assert DateTime.diff(token.expires_at, DateTime.utc_now()) > thousand_hours
      assert project.id == token.project_id
    end
  end
end
