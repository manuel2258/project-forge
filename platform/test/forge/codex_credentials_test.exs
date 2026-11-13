defmodule Forge.CodexCredentialsTest do
  @moduledoc """
  A Codex credential on the platform's side: its shape check, what a kind declares, the hold a
  ChatGPT login is under, and what a run hands back (`docs/design/codex.md` § Credentials;
  `docs/design/credentials.md` § Holding a login, § A login comes back).
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Ecto.Multi
  alias Forge.{Conversations, Credentials, Events, FakeWorker, Harness, Jobs, Repo}
  alias Forge.Credentials.Credential
  alias Forge.Harness.Codex
  alias Forge.Jobs.{Run, Runs}

  @marker "MARKER-never-echo-this"

  # A JWT-shaped id token whose claim carries a plan, unsigned: the platform reads it for display
  # and decides nothing on it.
  defp id_token(plan \\ "plus") do
    claims = %{"https://api.openai.com/auth" => %{"chatgpt_plan_type" => plan}}
    "h." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".s"
  end

  defp login(account \\ "acct-1", extra \\ %{}) do
    Map.merge(
      %{
        "tokens" => %{
          "id_token" => id_token(),
          "access_token" => "at-#{@marker}",
          "refresh_token" => "rt-#{@marker}",
          "account_id" => account
        },
        "last_refresh" => "2026-11-01T00:00:00Z"
      },
      extra
    )
    |> Jason.encode!()
  end

  defp check(text), do: Codex.check("chatgpt_login", %{"token" => text})

  describe "the shape of a ChatGPT login" do
    test "a login in ChatGPT mode with its three tokens and its account is accepted" do
      assert {:ok, []} = check(login())
      assert {:ok, []} = check(login("acct-1", %{"auth_mode" => "chatgpt"}))
    end

    test "what it says of itself is its account and its plan, the latter display only" do
      assert Codex.attributes("chatgpt_login", %{"token" => login("acct-9")}) ==
               %{account_id: "acct-9", plan: "plus"}

      assert Codex.account_id(login("acct-9")) == "acct-9"
      assert Codex.account_id("not json") == nil
      assert Codex.account_id(nil) == nil
    end

    test "a plan that does not decode is no plan, and no crash" do
      for bad <- ["x", "a.b.c", "a." <> Base.url_encode64("[]", padding: false) <> ".c"] do
        text =
          login()
          |> Jason.decode!()
          |> put_in(["tokens", "id_token"], bad)
          |> Jason.encode!()

        assert %{account_id: "acct-1", plan: nil} =
                 Codex.attributes("chatgpt_login", %{"token" => text})
      end
    end

    test "each way it can be wrong is refused with a fixed phrase that quotes nothing" do
      too_big = login("acct-1", %{"pad" => String.duplicate("x", 70_000)})

      missing =
        login() |> Jason.decode!() |> update_in(["tokens"], &Map.delete(&1, "refresh_token"))

      for {text, phrase} <- [
            {too_big, "is too large to be a ChatGPT login"},
            {~s({"tokens": #{@marker}), "is not JSON"},
            {~s(["#{@marker}"]), "is not a ChatGPT login"},
            {login("a", %{"auth_mode" => "apikey #{@marker}"}), "is not in ChatGPT mode"},
            {login("a", %{"OPENAI_API_KEY" => "sk-#{@marker}"}),
             "holds an API key, which this does not take"},
            {Jason.encode!(missing), "is not a ChatGPT login: it is missing its tokens"},
            {~s({"tokens": null}), "is not a ChatGPT login: it is missing its tokens"}
          ] do
        assert {:error, {:malformed, ^phrase}} = check(text)
        refute phrase =~ @marker
      end
    end

    test "an access token is one non-empty line" do
      assert {:ok, []} = Codex.check("access_token", %{"token" => "tok-123"})

      for bad <- ["", "a\nb", "a\rb", String.duplicate("x", 5_000)] do
        assert {:error, {:malformed, _phrase}} = Codex.check("access_token", %{"token" => bad})
      end

      assert {:error, {:malformed, _}} = Codex.check("api_key", %{"token" => "x"})
    end
  end

  describe "kinds declare how they are held" do
    test "a login is exclusive and comes back; nothing else is either" do
      assert Harness.traits("codex", "chatgpt_login") ==
               %{exclusive: true, returns: true, checked: :shape}

      assert Harness.traits("codex", "access_token") ==
               %{exclusive: false, returns: false, checked: :shape}

      for kind <- ["api_key", "oauth"] do
        assert Harness.traits("claude_code", kind) ==
                 %{exclusive: false, returns: false, checked: :provider}
      end

      # A kind this harness does not take declares nothing, rather than being exclusive by luck.
      assert %{exclusive: false, returns: false} = Harness.traits("codex", "oauth")
      assert %{exclusive: false} = Harness.traits("nobody", "x")
    end

    test "the platform's registry and the grammar's list the same harnesses" do
      assert Harness.names() == Enum.sort(ForgeCore.Harness.names())
    end
  end

  describe "saving one" do
    setup do
      %{user: user_fixture()}
    end

    test "a login is saved on its shape, claims no check with OpenAI, and keeps its account",
         %{user: user} do
      assert {:ok, credential} =
               Credentials.create(user, %{
                 name: "mine",
                 harness: "codex",
                 kind: "chatgpt_login",
                 secret: login("acct-7")
               })

      assert %{account_id: "acct-7", plan: "plus", checked_at: nil, check_error: nil} = credential
      assert credential.models in [nil, []]
      assert credential.renewed_at == nil
    end

    test "an access token is saved with the date its owner gave", %{user: user} do
      assert {:ok, credential} =
               Credentials.create(user, %{
                 name: "ws",
                 harness: "codex",
                 kind: "access_token",
                 secret: "tok-1",
                 expires_on: "2027-01-31"
               })

      assert credential.expires_on == ~D[2027-01-31]
      assert credential.account_id == nil
    end

    test "a login that is wrong is refused, and nothing that was pasted comes back", %{user: user} do
      for bad <- [~s({"tokens": #{@marker}), ~s(["#{@marker}"]), "#{@marker}"] do
        assert {:error, changeset} =
                 Credentials.create(user, %{
                   name: "bad",
                   harness: "codex",
                   kind: "chatgpt_login",
                   secret: bad
                 })

        refute inspect(changeset) =~ @marker
        assert [secret: {message, _}] = changeset.errors
        refute message =~ @marker
      end

      assert Repo.aggregate(Credential, :count) == 0
    end

    test "an API key is not a kind of Codex credential", %{user: user} do
      assert {:error, changeset} =
               Credentials.create(user, %{
                 name: "k",
                 harness: "codex",
                 kind: "api_key",
                 secret: "sk-x"
               })

      assert changeset.errors[:kind]
    end

    test "checking again asks nobody and changes nothing", %{user: user} do
      {:ok, credential} =
        Credentials.create(user, %{
          name: "mine",
          harness: "codex",
          kind: "chatgpt_login",
          secret: login()
        })

      assert {:ok, again} = Credentials.recheck(user, credential.id)
      assert again.checked_at == nil
    end

    test "the field a login is pasted into is filtered from request logs" do
      filtered = Phoenix.Logger.filter_values(%{"credential" => %{"secret" => login()}})
      assert filtered == %{"credential" => %{"secret" => "[FILTERED]"}}
    end
  end

  # -- holds and returns, on real jobs ---------------------------------------------------------

  describe "a login is held by one run at a time" do
    setup do
      config = Application.get_env(:forge, Forge.Jobs)

      Application.put_env(
        :forge,
        Forge.Jobs,
        Keyword.put(config, :data_dir, tmp_dir("codex-credentials-data"))
      )

      on_exit(fn -> Application.put_env(:forge, Forge.Jobs, config) end)

      bare = seeded_repo()
      name = "codex#{System.unique_integer([:positive])}"
      {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})
      owner = member_fixture(project, :admin)

      worker = FakeWorker.connect(harness: "codex", project: project)
      other = FakeWorker.connect(harness: "codex", project: project)
      funded!(project)

      %{project: project, owner: owner, worker: worker, other: other}
    end

    defp login!(ctx, name \\ nil) do
      credential =
        credential_fixture(ctx.owner, %{
          harness: "codex",
          kind: "chatgpt_login",
          name: name || "login-#{System.unique_integer([:positive])}",
          secret: login("acct-1")
        })

      Repo.update_all(from(c in Credential, where: c.id == ^credential.id),
        set: [account_id: "acct-1"]
      )

      pool!(ctx.project, credential)
    end

    defp chat(ctx) do
      {:ok, chat} = Conversations.open(ctx.project, "hello", harness: "codex")
      chat
    end

    test "a second job waits, with the sentence, and the first is unaffected", ctx do
      credential = login!(ctx)
      first = chat(ctx)
      second = chat(ctx)

      assert {:ok, _} = Jobs.assign(first, ctx.worker)
      assert Jobs.get!(first.id).credential_id == credential.id
      assert [%{exclusive: true}] = Repo.all(from r in Run, where: r.job_id == ^first.id)

      assert {:error, {:held, :codex}} = Jobs.assign(second, ctx.other)
      assert Jobs.get!(second.id).status == :pending
      assert {:error, {:held, :codex}} = Credentials.for_job(Jobs.get!(second.id))
    end

    test "the scheduler says so, once, and names nothing that holds it", ctx do
      login!(ctx)
      first = chat(ctx)
      second = chat(ctx)
      {:ok, _} = Jobs.assign(first, ctx.worker)
      start_supervised!(Forge.Jobs.Scheduler)

      Forge.Jobs.Scheduler.tick()
      Forge.Jobs.Scheduler.tick()

      assert [%{payload: %{"reason" => "held", "text" => text}}] =
               second.id |> Events.for_job() |> Enum.filter(&(&1.type == "job.waiting"))

      assert text == "Waiting for a Codex login: all in this project's pool are in use."
      refute text =~ first.id
    end

    test "a free login is taken in preference to a held one", ctx do
      ids = [login!(ctx).id, login!(ctx).id]
      first = chat(ctx)
      {:ok, _} = Jobs.assign(first, ctx.worker)
      held = Jobs.get!(first.id).credential_id
      assert held in ids

      second = chat(ctx)
      assert {:ok, _} = Jobs.assign(second, ctx.other)
      assert Jobs.get!(second.id).credential_id == hd(ids -- [held])
    end

    test "every way a run ends frees it for the next", ctx do
      login!(ctx)

      ends = [
        {"requeue", fn job -> Jobs.requeue(job.id, :worker_lost) end},
        {"hibernate", fn job -> Jobs.hibernate(job.id, nil, "idle") end}
      ]

      for {_name, end_run} <- ends do
        first = chat(ctx)
        {:ok, _} = Jobs.assign(first, ctx.worker)
        {:ok, blocked} = {:ok, chat(ctx)}
        assert {:error, {:held, :codex}} = Jobs.assign(blocked, ctx.other)

        end_run.(Jobs.get!(first.id))

        assert [] ==
                 Credentials.held(
                   Enum.map(Credentials.pool(ctx.project.id, "codex"), & &1.id),
                   blocked.id
                 )

        assert {:ok, _} = Jobs.assign(Jobs.get!(blocked.id), ctx.other)

        # Leave it free for the next round.
        Jobs.requeue(blocked.id, :worker_lost)
      end
    end

    test "a platform restart that finds the machine gone frees it", ctx do
      login!(ctx)
      first = chat(ctx)
      {:ok, _} = Jobs.assign(first, ctx.worker)

      Repo.update_all(from(w in Forge.Workers.Worker, where: w.id == ^ctx.worker.id),
        set: [status: :destroyed]
      )

      assert Jobs.recover() == 1
      blocked = chat(ctx)
      assert {:ok, _} = Jobs.assign(blocked, ctx.other)
    end

    # The job's own run is not another's, but a login it held and another job has since taken is:
    # restarting, it moves to the free one rather than waiting on, or stealing, the held one.
    test "a job whose login another job has taken moves to a free one", ctx do
      taken = login!(ctx)
      first = chat(ctx)
      {:ok, _} = Jobs.assign(first, ctx.worker)
      assert Jobs.get!(first.id).credential_id == taken.id
      Jobs.requeue(first.id, :worker_lost)

      second = chat(ctx)
      {:ok, _} = Jobs.assign(second, ctx.other)
      assert Jobs.get!(second.id).credential_id == taken.id

      free = login!(ctx)
      assert {:ok, %Credential{id: id}} = Credentials.for_job(Jobs.get!(first.id))
      assert id == free.id
    end

    test "a job restarts on the login it already holds", ctx do
      credential = login!(ctx)
      first = chat(ctx)
      {:ok, _} = Jobs.assign(first, ctx.worker)
      # Its own run, still live, is not another's.
      assert {:ok, ^credential} =
               {Credentials.for_job(Jobs.get!(first.id)) |> elem(0), credential}
    end

    test "the database refuses a second live exclusive run on one login", ctx do
      credential = login!(ctx)
      a = chat(ctx)
      b = chat(ctx)
      now = DateTime.utc_now(:second)

      assert {:ok, _} =
               Multi.new() |> Runs.open(a, ctx.worker, credential, now) |> Repo.transaction()

      assert {:error, :run, %Ecto.Changeset{} = refused, _changes} =
               Multi.new() |> Runs.open(b, ctx.other, credential, now) |> Repo.transaction()

      assert [credential_id: {_message, constraint}] = refused.errors
      assert constraint[:constraint] == :unique
    end

    test "a Claude token and an access token are held by any number at once", ctx do
      token =
        credential_fixture(ctx.owner, %{harness: "codex", kind: "access_token", secret: "tok-1"})

      pool!(ctx.project, token)

      for worker <- [ctx.worker, ctx.other] do
        assert {:ok, _} = Jobs.assign(chat(ctx), worker)
      end

      assert [false, false] =
               Repo.all(from r in Run, order_by: r.inserted_at, select: r.exclusive)

      claude = Forge.Projects.get!(ctx.project.id) |> Map.fetch!(:id)
      assert [_] = Credentials.pool(claude, "claude_code")
    end

    test "a project with no Codex credential at all is not told to wait", ctx do
      assert {:error, {:no_credential, :none_assigned}} = Credentials.for_job(chat(ctx))
    end

    test "held and limited together wait for the reset, not for a hold", ctx do
      credential = login!(ctx)
      {:ok, _} = Jobs.assign(chat(ctx), ctx.worker)

      limited =
        credential_fixture(ctx.owner, %{harness: "codex", kind: "chatgpt_login", secret: login()})

      pool!(ctx.project, limited)

      reset = DateTime.add(DateTime.utc_now(), 3600)

      {:ok, _} =
        Events.append("job.harness.rate_limit", :system, %{
          payload: %{
            "credential_id" => limited.id,
            "status" => "rejected",
            "rate_limit_type" => "five_hour",
            "resets_at" => DateTime.to_unix(reset)
          }
        })

      assert credential.id != limited.id
      assert {:error, {:limited, _until}} = Credentials.for_job(chat(ctx))
    end
  end
end
