defmodule Forge.CredentialsTest do
  @moduledoc """
  Inference credentials: whose they are, what the provider said about them, and that the secret
  goes nowhere it should not. `docs/design/credentials.md` § What a credential is and § Checked on
  save.

  The provider is a `Req.Test` stub owned by each test's own process, so this file runs async
  without writing any node-global configuration.
  """

  use Forge.DataCase, async: true

  import Forge.AccountsFixtures

  import Forge.ForgeFixtures,
    only: [
      chat_fixture: 1,
      run!: 2,
      credential_fixture: 1,
      credential_fixture: 2,
      join!: 3,
      pool!: 2,
      project_fixture: 0
    ]

  alias Forge.Credentials
  alias Forge.Credentials.Credential
  alias Forge.Events.Event
  alias Forge.Provisioning.Vault

  @token "sk-ant-api03-must-never-be-seen"

  setup do
    %{user: user_fixture()}
  end

  # The provider accepts, listing two models, and tells the test what it was sent.
  defp accepting do
    test = self()

    Req.Test.stub(Forge.Harness.ClaudeCode, fn conn ->
      send(test, {:asked, conn.req_headers})
      send(test, {:asked_at, conn.host, conn.request_path, conn.query_string})

      Req.Test.json(conn, %{
        "data" => [
          %{"id" => "claude-opus-5", "display_name" => "Claude Opus 5"},
          %{"id" => "claude-haiku-4-5"},
          # A row with no id is no model, whatever it is called.
          %{"display_name" => "a row with no id at all"}
        ]
      })
    end)
  end

  defp answering(status) do
    test = self()

    Req.Test.stub(Forge.Harness.ClaudeCode, fn conn ->
      send(test, {:asked, conn.req_headers})
      # Everything the request carried, echoed back: an error path that prints the response
      # prints the token, which is what the assertions below would catch.
      conn
      |> Plug.Conn.put_resp_header("x-echo", inspect(conn.req_headers))
      |> Plug.Conn.send_resp(status, "you sent " <> inspect(conn.req_headers))
    end)
  end

  defp add(user, attrs \\ %{}) do
    Credentials.create(
      user,
      Enum.into(attrs, %{name: "mine", harness: "claude_code", kind: "api_key", secret: @token})
    )
  end

  defp sealed(%Credential{id: id}),
    do: Repo.one(from c in Credential, where: c.id == ^id, select: c.secret)

  describe "adding one" do
    test "an accepted secret is saved sealed, with the models the provider listed", %{user: user} do
      accepting()

      assert {:ok, credential} = add(user, secret: "  #{@token}\n")

      assert credential.models == [
               %{"id" => "claude-opus-5", "name" => "Claude Opus 5"},
               %{"id" => "claude-haiku-4-5", "name" => "claude-haiku-4-5"}
             ]

      assert credential.checked_at
      assert credential.check_error == nil

      # Trimmed, sealed, and opened back whole.
      refute sealed(credential) =~ @token
      assert Credential.open(sealed(credential)) == {:ok, %{"token" => @token}}

      assert_received {:asked, headers}
      assert {"x-api-key", @token} in headers
    end

    # The request itself, which the stub would answer however it was made: pointed at the wrong
    # host or path it would go on "accepting". `anthropic-version` is not decoration — the real
    # API refuses a request without it, which would make every credential unchecked while this
    # stayed green — and `limit=100` is what makes one request list an account's models. Moved
    # here from the worker's probe, which made this request with the machine's token until a
    # machine stopped holding one.
    test "the check asks the documented endpoint, with the version header the API requires",
         %{user: user} do
      accepting()
      assert {:ok, _credential} = add(user)

      assert_received {:asked_at, "api.anthropic.com", "/v1/models", "limit=100"}
      assert_received {:asked, headers}
      assert {"anthropic-version", "2023-06-01"} in headers
    end

    # The two kinds are two different headers, and sending one as the other is a 401.
    test "a subscription token is sent as a bearer with the OAuth beta", %{user: user} do
      accepting()

      assert {:ok, _credential} = add(user, kind: "oauth")

      assert_received {:asked, headers}
      assert {"authorization", "Bearer " <> @token} in headers
      assert {"anthropic-beta", "oauth-2025-04-20"} in headers
      refute List.keymember?(headers, "x-api-key", 0)
    end

    test "a secret the provider refuses is not saved", %{user: user} do
      answering(401)

      assert {:error, changeset} = add(user)
      assert %{secret: ["was refused by the provider"]} = errors_on(changeset)
      assert Repo.aggregate(Credential, :count) == 0
    end

    # A platform that cannot reach the provider must still be able to hold a credential its
    # workers can use. And the reason is a phrase chosen by the driver, never the response: the
    # stub echoes the request, headers and all, into its answer.
    test "an unreachable provider saves it unchecked, and the reason carries none of the request",
         %{user: user} do
      answering(503)

      assert {:ok, credential} = add(user)
      assert credential.check_error == "HTTP 503"
      refute credential.check_error =~ @token
      assert credential.models == nil
      assert credential.checked_at == nil
    end

    test "a transport failure is named by its reason and nothing else", %{user: user} do
      Req.Test.stub(Forge.Harness.ClaudeCode, &Req.Test.transport_error(&1, :econnrefused))
      assert {:ok, %{check_error: "econnrefused"}} = add(user, name: "a")

      Req.Test.stub(Forge.Harness.ClaudeCode, &Req.Test.transport_error(&1, :timeout))
      assert {:ok, %{check_error: "timed out"}} = add(user, name: "b")
    end

    test "a blank form costs no request", %{user: user} do
      accepting()

      assert {:error, changeset} = add(user, name: "  ")
      assert %{name: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} = add(user, secret: "   ")
      assert %{secret: ["is required"]} = errors_on(changeset)

      refute_received {:asked, _headers}
    end

    test "a harness this node does not know is refused, and so is a kind it does not take",
         %{user: user} do
      accepting()

      assert {:error, changeset} = add(user, harness: "nothing")
      assert %{harness: ["is not a harness this node knows"]} = errors_on(changeset)

      assert {:error, changeset} = add(user, kind: "password")
      assert %{kind: ["is not a kind of secret Claude Code takes"]} = errors_on(changeset)
    end

    test "a name is one per person among live credentials, and free again once revoked",
         %{user: user} do
      accepting()

      assert {:ok, first} = add(user)
      assert {:error, changeset} = add(user)
      assert %{name: ["is already one of your credentials"]} = errors_on(changeset)

      # Somebody else's name is nothing to do with this one.
      assert {:ok, _theirs} = add(user_fixture())

      assert {:ok, _revoked} = Credentials.revoke(user, first.id)
      assert {:ok, _replacement} = add(user)
    end
  end

  describe "whose it is" do
    # The guard every id-taking function carries, aimed at each one: an outsider asking about a
    # credential gets exactly what asking about one that does not exist gets.
    test "another person's credential is not listed, read, rechecked or revoked",
         %{user: user} do
      accepting()
      {:ok, mine} = add(user)
      outsider = user_fixture()

      assert Credentials.list(outsider) == []
      assert Credentials.get(outsider, mine.id) == nil
      assert Credentials.recheck(outsider, mine.id) == {:error, :not_found}
      assert Credentials.revoke(outsider, mine.id) == {:error, :not_found}

      assert %{revoked_at: nil, checked_at: checked_at} = Credentials.get(user, mine.id)
      assert checked_at == mine.checked_at
      assert sealed(mine)
    end

    test "an id that is not an id is simply not found", %{user: user} do
      assert Credentials.get(user, "not-a-uuid") == nil
      assert Credentials.get(user, nil) == nil
      assert Credentials.revoke(user, "not-a-uuid") == {:error, :not_found}
    end
  end

  describe "the secret" do
    # `load_in_query: false`: the column is not selected unless somebody names it, so a list on a
    # page cannot carry it however it is rendered.
    test "no ordinary read carries it, not even sealed", %{user: user} do
      accepting()
      {:ok, credential} = add(user)

      assert [%{secret: nil}] = Credentials.list(user)
      assert %{secret: nil} = Credentials.get(user, credential.id)
      assert %{secret: nil} = Repo.get(Credential, credential.id)
    end

    # Ecto leaves a redacted field out of `inspect/1` altogether, which is what a crash report or a
    # log line built from the struct would otherwise print.
    test "inspecting a row that does carry it leaves it out", %{user: user} do
      accepting()
      {:ok, credential} = add(user)
      sealed = sealed(credential)

      loaded =
        Repo.one(
          from c in Credential, where: c.id == ^credential.id, select_merge: %{secret: c.secret}
        )

      assert loaded.secret == sealed
      refute inspect(loaded) =~ "secret:"
      refute inspect(loaded) =~ sealed
    end

    # Each table seals under its own label, so ciphertext moved from one to the other is refused
    # rather than opened as a secret of the wrong kind.
    test "a provider credential's ciphertext does not open here, nor this one there" do
      provider_sealed = Vault.seal(%{"token" => @token})
      inference_sealed = Credential.seal(@token)

      assert Credential.open(provider_sealed) == :error
      assert Vault.open(inference_sealed) == :error
      assert Credential.open(inference_sealed) == {:ok, %{"token" => @token}}
    end

    test "the event log names a credential and never holds it", %{user: user} do
      accepting()
      {:ok, credential} = add(user)
      {:ok, _revoked} = Credentials.revoke(user, credential.id)

      events =
        Repo.all(from e in Event, where: e.type in ["credential.added", "credential.revoked"])

      assert Enum.map(events, & &1.type) |> Enum.sort() == [
               "credential.added",
               "credential.revoked"
             ]

      for event <- events do
        assert event.payload["credential_id"] == credential.id
        assert event.payload["name"] == "mine"
        refute inspect(event) =~ @token
        refute inspect(event) =~ "XCP."
      end
    end

    # Phoenix filters `password` by default and nothing else, so a form field named `secret` or
    # `token` went into the debug log of every request and every LiveView event that carried it.
    test "a form's secret is filtered out of the request and event logs" do
      filtered =
        Phoenix.Logger.filter_values(%{
          "credential" => %{"name" => "mine", "secret" => @token, "token" => @token}
        })

      assert filtered == %{
               "credential" => %{
                 "name" => "mine",
                 "secret" => "[FILTERED]",
                 "token" => "[FILTERED]"
               }
             }
    end
  end

  describe "revoking" do
    # The struct never carries the secret, so a changeset setting it to nil compares nil with nil
    # and writes nothing — the token would survive a revocation that reported success.
    test "destroys the secret and keeps the row", %{user: user} do
      accepting()
      {:ok, credential} = add(user)

      assert {:ok, revoked} = Credentials.revoke(user, credential.id)
      assert revoked.revoked_at

      assert sealed(credential) == nil
      assert %{revoked_at: %DateTime{}} = Repo.get(Credential, credential.id)
    end

    test "a revoked credential cannot be revoked again or rechecked", %{user: user} do
      accepting()
      {:ok, credential} = add(user)
      {:ok, _revoked} = Credentials.revoke(user, credential.id)

      assert Credentials.revoke(user, credential.id) == {:error, :not_found}
      assert Credentials.recheck(user, credential.id) == {:error, :not_found}
      assert [%{revoked_at: %DateTime{}}] = Credentials.list(user)
    end

    # The rule is the database's too, so no path that skips `Credentials` can leave a live row
    # with nothing in it.
    test "the database refuses a live credential with no secret", %{user: user} do
      assert_raise Postgrex.Error, ~r/secret_until_revoked/, fn ->
        Repo.insert_all(Credential, [
          %{
            id: Ecto.UUID.generate(),
            user_id: user.id,
            name: "empty",
            harness: "claude_code",
            kind: "api_key",
            inserted_at: DateTime.utc_now(:second),
            updated_at: DateTime.utc_now(:second)
          }
        ])
      end
    end
  end

  describe "rechecking" do
    test "records what the provider says now", %{user: user} do
      accepting()
      {:ok, credential} = add(user)

      answering(401)
      assert {:ok, refused} = Credentials.recheck(user, credential.id)
      assert refused.check_error == "refused by the provider"
      # Kept and marked, not revoked: that is the owner's decision.
      assert refused.revoked_at == nil

      answering(502)
      assert {:ok, unreachable} = Credentials.recheck(user, credential.id)
      assert unreachable.check_error == "HTTP 502"

      accepting()
      assert {:ok, accepted} = Credentials.recheck(user, credential.id)
      assert accepted.check_error == nil
      assert length(accepted.models) == 2
    end

    test "a secret this node cannot open says so rather than crashing", %{user: user} do
      accepting()
      {:ok, credential} = add(user)

      Repo.update_all(from(c in Credential, where: c.id == ^credential.id),
        set: [secret: Vault.seal(%{"token" => @token})]
      )

      assert {:ok, %{check_error: "cannot be decrypted on this node; add it again"}} =
               Credentials.recheck(user, credential.id)
    end
  end

  describe "the pool" do
    setup %{user: user} do
      project = project_fixture()
      join!(project, user, :member)
      %{project: project, credential: credential_fixture(user)}
    end

    test "the owner may put a credential in a project they are in, and it is recorded",
         %{user: user, project: project, credential: credential} do
      assert {:ok, _} = Credentials.assign(user, credential.id, project.id)
      assert [%{id: id}] = Credentials.pool(project.id, "claude_code")
      assert id == credential.id

      assert [%{id: funded}] = Credentials.projects(credential)
      assert funded == project.id

      assert :ok = Credentials.unassign(user, credential.id, project.id)
      assert Credentials.pool(project.id, "claude_code") == []

      types =
        Repo.all(
          from e in Event,
            where: e.project_id == ^project.id and like(e.type, "credential.%"),
            order_by: e.seq,
            select: e.type
        )

      assert types == ["credential.assigned", "credential.unassigned"]
    end

    # The rule that makes the pool somebody's decision: an admin of the project who does not own
    # the credential is refused, because it is not their money.
    test "somebody else may not, even as an admin of the project",
         %{project: project, credential: credential} do
      admin = user_fixture()
      join!(project, admin, :admin)

      assert Credentials.assign(admin, credential.id, project.id) == {:error, :not_found}
      assert Credentials.unassign(admin, credential.id, project.id) == {:error, :not_found}
      assert Credentials.pool(project.id, "claude_code") == []
    end

    test "the owner may not, for a project they are not in", %{user: user, credential: credential} do
      elsewhere = project_fixture()

      assert Credentials.assign(user, credential.id, elsewhere.id) == {:error, :not_a_member}
      assert Credentials.assign(user, credential.id, "not-a-uuid") == {:error, :not_a_member}
      assert Credentials.pool(elsewhere.id, "claude_code") == []
    end

    test "a revoked credential cannot be put in a pool", %{user: user, project: project} do
      credential = credential_fixture(user)
      {:ok, _} = Credentials.revoke(user, credential.id)

      assert Credentials.assign(user, credential.id, project.id) == {:error, :not_found}
    end

    # Revocation reaches every job that has not started and every one that starts again, on the
    # next pass, because the pool is read with it filtered — the assignment itself stays as the
    # record of what the credential funded.
    test "revoking takes a credential out of every pool at once",
         %{user: user, project: project, credential: credential} do
      {:ok, _} = Credentials.assign(user, credential.id, project.id)
      {:ok, _} = Credentials.revoke(user, credential.id)

      assert Credentials.pool(project.id, "claude_code") == []
      assert [_still_recorded] = Credentials.projects(credential)
    end

    test "a pool is per harness", %{user: user, project: project} do
      other = credential_fixture(user, harness: "another")
      pool!(project, other)

      assert Credentials.pool(project.id, "claude_code") == []
      assert [%{harness: "another"}] = Credentials.pool(project.id, "another")
    end
  end

  # Noon, so that a day either side of it is a whole day away from both edges.
  @now ~U[2026-09-20 12:00:00Z]

  # `n` credentials in `project`'s pool, oldest first. `inserted_at` is second-granular, so they
  # are aged by hand, a minute apart, for the order to be about age and not insertion.
  defp pool_in_order!(project, user, n) do
    for i <- 1..n do
      credential = pool!(project, credential_fixture(user))

      Repo.update_all(from(c in Credential, where: c.id == ^credential.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), (i - n - 1) * 60)]
      )

      credential
    end
  end

  defp on(job, credential) do
    Repo.update_all(from(j in Forge.Jobs.Job, where: j.id == ^job.id),
      set: [credential_id: credential && credential.id]
    )

    job
  end

  # A run in `project` on `credential`, started at `started_at`, that cost `cost`.
  defp spent!(project, credential, cost, started_at) do
    run!(chat_fixture(%{project: project}),
      credential: credential,
      cost: cost,
      started_at: started_at
    )
  end

  # What the harness said about `credential`'s account, arriving the way a worker's report does.
  # A five-hour report unless `extra` says otherwise: every report recorded in `capacity.md` was.
  defp reports!(project, credential, status, resets_at, extra \\ %{}) do
    job = on(chat_fixture(%{project: project}), credential)

    payload =
      Map.merge(
        %{
          status: status,
          resets_at: resets_at && DateTime.to_unix(resets_at),
          rate_limit_type: "five_hour"
        },
        extra
      )

    :ok =
      Forge.Jobs.record_harness_event(job.id, %{type: "job.harness.rate_limit", payload: payload})
  end

  describe "how a job picks" do
    setup %{user: user} do
      project = project_fixture()
      join!(project, user, :member)
      %{project: project}
    end

    defp job_in(project, attrs \\ %{}) do
      %Forge.Jobs.Job{project_id: project.id, kind: :chat, credential_id: attrs[:credential_id]}
    end

    test "nothing in the pool is its own answer", %{project: project} do
      assert Credentials.for_job(job_in(project)) == {:error, {:no_credential, :none_assigned}}
    end

    test "a job that has not started takes the oldest of equals", %{
      user: user,
      project: project
    } do
      _second = pool!(project, credential_fixture(user))
      first = pool!(project, credential_fixture(user))

      # `inserted_at` is second-granular, so two made in one test tie; aged by hand, and made in
      # the opposite order, so the assertion is about the age and not the insertion order.
      Repo.update_all(from(c in Credential, where: c.id == ^first.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -3600)]
      )

      assert {:ok, %{id: id}} = Credentials.for_job(job_in(project))
      assert id == first.id
    end

    # **It keeps the one it started on**, whatever order the pool is in: a job's cost is recorded
    # on the job, so one that moved would land its whole cost on whichever it ended on.
    test "a job keeps the credential it started on while that is usable",
         %{user: user, project: project} do
      _first = pool!(project, credential_fixture(user))
      kept = pool!(project, credential_fixture(user))

      assert {:ok, %{id: id}} = Credentials.for_job(job_in(project, credential_id: kept.id))
      assert id == kept.id
    end

    test "and picks again when it is revoked or taken out of the project",
         %{user: user, project: project} do
      other = pool!(project, credential_fixture(user))
      revoked = pool!(project, credential_fixture(user))
      {:ok, _} = Credentials.revoke(user, revoked.id)

      assert {:ok, %{id: id}} = Credentials.for_job(job_in(project, credential_id: revoked.id))
      assert id == other.id

      unpooled = credential_fixture(user)
      assert {:ok, %{id: ^id}} = Credentials.for_job(job_in(project, credential_id: unpooled.id))
    end

    # Least spent *today*: three credentials whose figures disagree about which that is by every
    # other measure. Oldest first says `a`, most spent today says `a`, least spent ever says `c`;
    # only today's figure says `b`.
    test "a job that has not started takes the one that has spent least today",
         %{user: user, project: project} do
      [a, b, c] = pool_in_order!(project, user, 3)

      spent!(project, a, "3.00", @now)
      spent!(project, b, "10.00", DateTime.add(@now, -1, :day))
      spent!(project, b, "1.00", @now)
      spent!(project, c, "2.00", @now)

      assert {:ok, %{id: id}} = Credentials.for_job(job_in(project), @now)
      assert id == b.id
    end

    test "a rate-limited credential is passed over, however little it has spent",
         %{user: user, project: project} do
      [limited, free] = pool_in_order!(project, user, 2)
      spent!(project, free, "5.00", @now)
      reports!(project, limited, "rejected", DateTime.add(@now, 3600))

      assert {:ok, %{id: id}} = Credentials.for_job(job_in(project), @now)
      assert id == free.id
    end

    # Time resolves this, not a person, so it is not the empty pool's answer: the scheduler leaves
    # the job pending and the ticket active on it. The earliest reset is when it may next go.
    test "everything limited is a wait until the earliest reset", %{user: user, project: project} do
      [later, sooner] = pool_in_order!(project, user, 2)
      reports!(project, later, "rejected", DateTime.add(@now, 7200))
      reports!(project, sooner, "rejected", DateTime.add(@now, 3600))

      assert Credentials.for_job(job_in(project), @now) ==
               {:error, {:limited, DateTime.add(@now, 3600)}}
    end

    # **A limited credential is left when another is free** (`credentials.md` § How a job picks):
    # waiting hours for a reset with a free credential beside it costs more than the prompt cache
    # a move loses. Only with every credential limited does the job wait, until the earliest reset
    # of them all — its own included.
    test "a job whose credential is rate-limited moves to a free one, and waits if none is",
         %{user: user, project: project} do
      [kept, free] = pool_in_order!(project, user, 2)
      reports!(project, kept, "rejected", DateTime.add(@now, 7200))

      assert {:ok, %{id: id}} = Credentials.for_job(job_in(project, credential_id: kept.id), @now)
      assert id == free.id

      reports!(project, free, "rejected", DateTime.add(@now, 3600))

      assert Credentials.for_job(job_in(project, credential_id: kept.id), @now) ==
               {:error, {:limited, DateTime.add(@now, 3600)}}

      # Once the one it moved to is free again, it stays there: the other is still limited.
      assert {:ok, %{id: ^id}} =
               Credentials.for_job(
                 job_in(project, credential_id: free.id),
                 DateTime.add(@now, 3600)
               )
    end
  end

  describe "what a credential has spent" do
    setup %{user: user} do
      project = project_fixture()
      join!(project, user, :member)
      %{project: project}
    end

    # `Forge.Spend.day/1`'s day, so the edges are exact: the last second of the day before and
    # the first of the day after are both outside it.
    test "is the cost of the jobs that started on it that day, per credential",
         %{user: user, project: project} do
      [a, b, idle] = pool_in_order!(project, user, 3)
      day = DateTime.to_date(@now)
      {midnight, next} = Forge.Spend.day(day)

      spent!(project, a, "1.25", midnight)
      spent!(project, a, "0.50", DateTime.add(next, -1))
      spent!(project, a, "9.00", DateTime.add(midnight, -1))
      spent!(project, a, "7.00", next)
      spent!(project, b, "2.00", @now)
      # What no credential paid for — every job before credentials existed — is nobody's.
      spent!(project, nil, "4.00", @now)

      assert Credentials.spent_today([a.id, b.id, idle.id], day) == %{
               a.id => Decimal.new("1.75"),
               b.id => Decimal.new("2.00")
             }

      assert Credentials.spent_today([a.id], Date.add(day, -1)) == %{a.id => Decimal.new("9.00")}
      assert Credentials.spent_today([b.id], day) == %{b.id => Decimal.new("2.00")}
    end
  end

  describe "a credential's rate limit" do
    setup %{user: user} do
      project = project_fixture()
      join!(project, user, :member)
      %{project: project}
    end

    # **One window per kind of limit.** A report about the five-hour window says nothing about
    # the week, so the latest five-hour `allowed` leaves a weekly block standing — the hole step 5
    # had, reading only the latest report whatever its type.
    test "is one window per type, and a later five-hour allowed hides no weekly block",
         %{user: user, project: project} do
      [credential] = pool_in_order!(project, user, 1)
      week = DateTime.add(@now, 2, :day)

      reports!(project, credential, "rejected", week, %{rate_limit_type: "seven_day"})
      reports!(project, credential, "allowed", DateTime.add(@now, 3600))

      assert Credentials.limited([credential.id], @now) == %{credential.id => week}
    end

    # Free only when every blocking window has reset, so the later of them.
    test "is limited until the last of its blocking windows resets",
         %{user: user, project: project} do
      [credential] = pool_in_order!(project, user, 1)
      week = DateTime.add(@now, 2, :day)

      reports!(project, credential, "rejected", DateTime.add(@now, 3600))
      reports!(project, credential, "rejected", week, %{rate_limit_type: "seven_day"})

      assert Credentials.limited([credential.id], @now) == %{credential.id => week}
    end

    # A report with no type is still a report: one that blocks, blocks. The rule fails towards
    # not spending.
    test "a report with no type is a window of its own, and blocks",
         %{user: user, project: project} do
      [credential] = pool_in_order!(project, user, 1)
      reset = DateTime.add(@now, 3600)

      reports!(project, credential, "rejected", reset, %{rate_limit_type: nil})
      reports!(project, credential, "allowed", reset)

      assert Credentials.limited([credential.id], @now) == %{credential.id => reset}

      assert %{"unknown" => %{limited: true}} =
               Credentials.windows([credential.id], @now)[credential.id]
    end

    # `unifiedWindows` — the shape a third-party report shows newer releases sending — gives the
    # figures for every window on the newest report. It is the newer figure for each window, and
    # never what decides whether one blocks: it carries no status, and a window that blocks keeps
    # its own reset.
    test "reads each window's figures from the newest report, and its block from its own",
         %{user: user, project: project} do
      [credential] = pool_in_order!(project, user, 1)
      week = DateTime.add(@now, 2, :day)
      hour = DateTime.add(@now, 3600)

      reports!(project, credential, "rejected", week, %{rate_limit_type: "seven_day"})

      reports!(project, credential, "allowed", hour, %{
        utilization: 0.4,
        windows: %{
          "five_hour" => %{utilization: 0.5, resets_at: DateTime.to_unix(hour)},
          "seven_day" => %{utilization: 1.0, resets_at: DateTime.to_unix(DateTime.add(week, 60))},
          "seven_day_opus" => %{utilization: 0.1, resets_at: DateTime.to_unix(week)}
        }
      })

      assert Credentials.windows([credential.id], @now) == %{
               credential.id => %{
                 "five_hour" => %{utilization: 0.5, resets_at: hour, limited: false},
                 "seven_day" => %{utilization: 1.0, resets_at: week, limited: true},
                 "seven_day_opus" => %{utilization: 0.1, resets_at: week, limited: false}
               }
             }
    end

    # A window past its reset rolled over, and nothing is known about the new one: it is gone
    # rather than drawn with the old figure.
    test "a window past its reset is no longer known", %{user: user, project: project} do
      [credential] = pool_in_order!(project, user, 1)

      reports!(project, credential, "allowed_warning", DateTime.add(@now, 60), %{
        utilization: 0.96
      })

      assert %{"five_hour" => %{utilization: 0.96}} =
               Credentials.windows([credential.id], @now)[credential.id]

      assert Credentials.windows([credential.id], DateTime.add(@now, 60)) == %{}
    end

    # The top bar's figure (`credentials.md` § Showing the windows): per window, the mean over the
    # credentials that reported one — a limited one counting as full — how many that is of those
    # with a window at all, and the soonest reset among them. A kind nobody reported is absent.
    test "the gauge is the mean of what was reported, a limited credential counting as full",
         %{user: user, project: project} do
      [said, limited, silent, never] = pool_in_order!(project, user, 4)
      soon = DateTime.add(@now, 600)
      hour = DateTime.add(@now, 3600)

      reports!(project, said, "allowed_warning", hour, %{
        utilization: 0.4,
        windows: %{"seven_day" => %{utilization: 1.7, resets_at: DateTime.to_unix(hour)}}
      })

      reports!(project, limited, "rejected", hour)
      reports!(project, silent, "allowed", soon)

      gauge = Credentials.gauge([said.id, limited.id, silent.id, never.id], @now)

      assert gauge["five_hour"] == %{mean: 0.7, reporting: 2, known: 3, soonest: soon}
      # A figure past full, from the worker, is drawn full rather than overflowing.
      assert gauge["seven_day"] == %{mean: 1.0, reporting: 1, known: 1, soonest: hour}
      assert Credentials.gauge([silent.id], @now)["five_hour"].mean == nil
      assert Credentials.gauge([never.id], @now) == %{}
    end

    # Every field is the worker's. None of these may crash the pass that reads them.
    test "a malformed report is read as saying less, never as a crash",
         %{user: user, project: project} do
      [credential] = pool_in_order!(project, user, 1)
      reset = DateTime.add(@now, 3600)

      reports!(project, credential, "rejected", reset, %{
        rate_limit_type: 7,
        utilization: "high",
        windows: 5
      })

      assert Credentials.windows([credential.id], @now) == %{
               credential.id => %{
                 "unknown" => %{utilization: nil, resets_at: reset, limited: true}
               }
             }

      reports!(project, credential, "allowed", reset, %{windows: %{"five_hour" => "full"}})
      assert Credentials.limited([credential.id], @now) == %{credential.id => reset}
    end

    # Two reports of no usable type are one window, and the newer is it. The newer one here is the
    # one the query returns *first* — rows come back ordered by type, `7` before a null — so the
    # answer depends on reading them by age rather than in the order they arrive.
    test "two reports of no usable type are one window, the newer of them",
         %{user: user, project: project} do
      [credential] = pool_in_order!(project, user, 1)
      reset = DateTime.add(@now, 3600)

      reports!(project, credential, "rejected", reset, %{rate_limit_type: nil})
      reports!(project, credential, "allowed", reset, %{rate_limit_type: 7})

      assert Credentials.limited([credential.id], @now) == %{}
    end

    test "is the latest report stamped with it", %{user: user, project: project} do
      [limited, recovered] = pool_in_order!(project, user, 2)
      reset = DateTime.add(@now, 3600)

      reports!(project, limited, "allowed", reset)
      reports!(project, limited, "rejected", reset)
      reports!(project, recovered, "rejected", reset)
      reports!(project, recovered, "allowed", reset)

      assert Credentials.limited([limited.id, recovered.id], @now) == %{limited.id => reset}
      # One credential's window says nothing about another's.
      assert Credentials.limited([recovered.id], @now) == %{}
    end

    # `capacity.md`'s reading, unchanged: a warning still permits, a reset already past is a
    # window that rolled over, and a report with no reset has no end to wait for.
    test "blocks only on a status that is not allowed, until a reset still to come",
         %{user: user, project: project} do
      [warned, rolled_over, endless, blocked] = pool_in_order!(project, user, 4)

      reports!(project, warned, "allowed_warning", DateTime.add(@now, 3600))
      reports!(project, rolled_over, "rejected", DateTime.add(@now, -1))
      reports!(project, endless, "rejected", nil)
      reports!(project, blocked, "rejected", DateTime.add(@now, 1))

      ids = [warned.id, rolled_over.id, endless.id, blocked.id]
      assert Credentials.limited(ids, @now) == %{blocked.id => DateTime.add(@now, 1)}
      assert Credentials.limited(ids, DateTime.add(@now, 1)) == %{}
    end

    # The reset is the worker's integer. One past the end of the calendar is a report that says
    # nothing — not a crash in every scheduler pass that reads it.
    test "a reset no calendar has is no limit, and no crash", %{user: user, project: project} do
      [credential] = pool_in_order!(project, user, 1)
      job = on(chat_fixture(%{project: project}), credential)

      :ok =
        Forge.Jobs.record_harness_event(job.id, %{
          type: "job.harness.rate_limit",
          payload: %{status: "rejected", resets_at: 1_000_000_000_000_000}
        })

      assert Credentials.limited([credential.id], @now) == %{}
      assert {:ok, %{id: id}} = Credentials.for_job(job_in(project), @now)
      assert id == credential.id
    end

    # Stamped when it arrives, from the job's row: a job whose credential is later replaced must
    # not carry its old account's window onto the new one.
    test "is stamped with the credential the job ran on, whatever the worker said",
         %{user: user, project: project} do
      [ran_on, somebody_elses] = pool_in_order!(project, user, 2)
      reset = DateTime.to_unix(DateTime.add(@now, 3600))

      forged = %{status: "rejected", resets_at: reset, credential_id: somebody_elses.id}
      job = on(chat_fixture(%{project: project}), ran_on)

      :ok =
        Forge.Jobs.record_harness_event(job.id, %{type: "job.harness.rate_limit", payload: forged})

      assert Credentials.limited([ran_on.id, somebody_elses.id], @now) ==
               %{ran_on.id => DateTime.from_unix!(reset)}

      # A job with no credential stamps none, rather than keeping the one it was sent.
      unfunded = chat_fixture(%{project: project})

      :ok =
        Forge.Jobs.record_harness_event(unfunded.id, %{
          type: "job.harness.rate_limit",
          payload: forged
        })

      assert Credentials.limited([somebody_elses.id], @now) == %{}
    end
  end
end

defmodule Forge.CredentialsLogTest do
  @moduledoc """
  That nothing the credential paths log carries the secret — at debug too, which is where request
  parameters go.

  **Its own module, and not async**, because the only way to see a debug line in this suite is to
  lower the node's log level, and `Logger.configure/1` is node-global. `Logger.put_process_level/2`
  does not reach below the primary level, which was tried: a debug leak passed unseen under it.
  ExUnit runs every async module before any synchronous one, and synchronous ones one at a time,
  so nothing else is running while the level is down.
  """

  use Forge.DataCase, async: false

  import ExUnit.CaptureLog
  import Forge.AccountsFixtures

  alias Forge.Credentials

  @moduletag :capture_log

  @token "sk-ant-api03-must-never-be-logged"

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    %{user: user_fixture()}
  end

  defp answering(status) do
    Req.Test.stub(Forge.Harness.ClaudeCode, fn conn ->
      Plug.Conn.send_resp(conn, status, "you sent " <> inspect(conn.req_headers))
    end)
  end

  defp add(user, name) do
    Credentials.create(user, %{
      name: name,
      harness: "claude_code",
      kind: "api_key",
      secret: @token
    })
  end

  test "nothing logged on any path carries it, at any level", %{user: user} do
    log =
      capture_log([level: :debug], fn ->
        answering(401)
        add(user, "refused")
        answering(500)
        {:ok, unchecked} = add(user, "unchecked")
        Credentials.recheck(user, unchecked.id)
        Req.Test.stub(Forge.Harness.ClaudeCode, &Req.Test.transport_error(&1, :closed))
        Credentials.recheck(user, unchecked.id)
        Credentials.revoke(user, unchecked.id)
      end)

    # The capture saw the debug level at all, or the refutation below proves nothing.
    assert log =~ "[debug]"
    refute log =~ @token
  end
end
