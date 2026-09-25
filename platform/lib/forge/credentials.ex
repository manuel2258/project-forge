defmodule Forge.Credentials do
  @moduledoc """
  Inference credentials: the secrets an agent authenticates with, each owned by a person.
  `docs/design/credentials.md`.

  **Every function that takes an id takes the acting user, and reads the row scoped to them.**
  An id arrives from a page and is the client's; a credential of somebody else's answers
  `:not_found` exactly as one that does not exist does, so the answer says nothing about what is
  on the node. There is no node-admin path: `node_admin` governs accounts and grants no room
  (`identity.md` § node_admin is account governance), and a credential is money.

  The guard is here rather than in a changeset because the rule is about the caller, and a
  changeset can be bypassed.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Accounts.User
  alias Forge.Credentials.{Credential, ProjectCredential}
  alias Forge.{Engine, Events, Harness, Projects, Repo, Spend}
  alias Forge.Events.Event
  alias Forge.Jobs.{Job, Run}
  alias Forge.Workers.Worker

  @doc """
  This user's credentials, live ones first, then by name. Revoked ones stay listed — they are
  the record of what was spent through them — and never carry a secret, since nothing loaded
  here does.
  """
  @spec list(User.t()) :: [Credential.t()]
  def list(%User{id: user_id}) do
    Repo.all(
      from c in Credential,
        where: c.user_id == ^user_id,
        order_by: [asc_nulls_first: c.revoked_at, asc: c.name]
    )
  end

  @doc "A credential of this user's, or nil. Never another user's, whatever the id."
  @spec get(User.t(), String.t() | nil) :: Credential.t() | nil
  def get(%User{id: user_id}, id) do
    case cast_id(id) do
      {:ok, id} -> Repo.one(from c in Credential, where: c.id == ^id and c.user_id == ^user_id)
      :error -> nil
    end
  end

  @doc """
  Adds a credential for `user`, after asking the provider whether it works.

  Three outcomes (`credentials.md` § Checked on save). **Accepted**: saved with the models it may
  use. **Refused**: not saved, and the changeset says so on `secret`. **Unreachable**: saved
  unchecked, with the reason in `check_error`, because a platform that cannot reach the provider
  must still be able to hold a credential its workers can use.

  The form is validated before the provider is asked, so a blank name costs no request.
  """
  @spec create(User.t(), map()) :: {:ok, Credential.t()} | {:error, Ecto.Changeset.t()}
  def create(%User{id: user_id}, attrs) do
    attrs = attrs |> stringify() |> Map.put("user_id", user_id)
    secret = attrs["secret"]
    changeset = Credential.create_changeset(%Credential{}, attrs)

    with {:ok, _valid} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, changeset} <- checked(changeset, secret) do
      insert(changeset, user_id)
    end
  end

  defp checked(changeset, secret) do
    harness = Ecto.Changeset.get_field(changeset, :harness)
    kind = Ecto.Changeset.get_field(changeset, :kind)
    {:ok, driver} = Harness.driver(harness)

    case driver.check(kind, %{"token" => String.trim(secret)}) do
      {:ok, models} ->
        {:ok, Ecto.Changeset.change(changeset, models: models, checked_at: now())}

      {:error, :refused} ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(:secret, "was refused by the provider")
         |> Map.put(:action, :insert)}

      {:error, {:unreachable, why}} ->
        {:ok, Ecto.Changeset.change(changeset, check_error: why)}
    end
  end

  defp insert(changeset, user_id) do
    Multi.new()
    |> Multi.insert(:credential, changeset)
    |> Events.log(:event, "credential.added", {:user, user_id}, fn %{credential: c} ->
      %{payload: describe(c)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{credential: credential}} -> {:ok, credential}
      {:error, :credential, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Asks the provider again, and records what it says: the models on success, the reason on
  anything else. A credential the provider now refuses is kept and marked, not revoked — revoking
  is the owner's decision, and a refusal may be the provider's outage rather than the token's.
  """
  @spec recheck(User.t(), String.t()) :: {:ok, Credential.t()} | {:error, :not_found}
  def recheck(%User{} = user, id) do
    with {:ok, credential, sealed} <- live_with_secret(user, id) do
      credential
      |> Ecto.Changeset.change(recheck_attrs(credential, sealed))
      |> Repo.update()
    end
  end

  defp recheck_attrs(credential, sealed) do
    {:ok, driver} = Harness.driver(credential.harness)

    with {:ok, secret} <- Credential.open(sealed),
         {:ok, models} <- driver.check(credential.kind, secret) do
      %{models: models, checked_at: now(), check_error: nil}
    else
      :error -> %{check_error: "cannot be decrypted on this node; add it again"}
      {:error, :refused} -> %{check_error: "refused by the provider", checked_at: now()}
      {:error, {:unreachable, why}} -> %{check_error: why}
    end
  end

  # The one read of the secret column, and it is by name: `load_in_query: false` keeps it out of
  # every other query in the platform.
  defp live_with_secret(%User{id: user_id}, id) do
    with {:ok, id} <- cast_id(id),
         {%Credential{} = credential, sealed} <-
           Repo.one(
             from c in Credential,
               where: c.id == ^id and c.user_id == ^user_id and is_nil(c.revoked_at),
               select: {c, c.secret}
           ) do
      {:ok, credential, sealed}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  Revokes a credential, and destroys its secret in the same statement.

  **The secret is overwritten with nothing, not left behind a flag.** A revoked credential is one
  its owner wants to stop existing and nothing will ever need it back; a flag would leave the
  token in the database, in every backup, for as long as the row lives. The row itself stays,
  because jobs reference it.

  An update statement rather than a changeset, deliberately: the struct never carries the secret,
  so `change(credential, secret: nil)` compares nil with nil, records no change, and writes
  nothing — the secret would survive a revocation that reported success.
  """
  @spec revoke(User.t(), String.t()) :: {:ok, Credential.t()} | {:error, :not_found}
  def revoke(%User{} = user, id) do
    case get(user, id) do
      %Credential{revoked_at: nil} = credential -> revoke_live(credential)
      _missing_or_revoked -> {:error, :not_found}
    end
  end

  # The owner and not-yet-revoked conditions repeat what `get/2` and the match in `revoke/2`
  # established, so removing either is an **equivalent mutant** in every sequential test and has
  # none: they are for two revocations racing, where the second must find nothing to update and
  # write no second event — which is what `:won` refuses.
  defp revoke_live(%Credential{} = credential) do
    now = now()

    Multi.new()
    |> Multi.update_all(
      :revoke,
      from(c in Credential,
        where:
          c.id == ^credential.id and c.user_id == ^credential.user_id and is_nil(c.revoked_at)
      ),
      set: [revoked_at: now, secret: nil, updated_at: now]
    )
    |> Multi.run(:won, fn _repo, %{revoke: {count, _rows}} ->
      if count == 1, do: {:ok, count}, else: {:error, :already_revoked}
    end)
    |> Events.log(:event, "credential.revoked", {:user, credential.user_id}, %{
      payload: describe(credential)
    })
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> {:ok, %{credential | revoked_at: now}}
      {:error, _step, _reason, _changes} -> {:error, :not_found}
    end
  end

  # -- the pool --------------------------------------------------------------------------------

  @doc """
  Puts a credential in a project's pool, so a job in that project may spend it.

  Refused unless the caller owns the credential, it is not revoked, *and* the caller is a member
  of the project (`docs/design/credentials.md` § The pool). The first stops an admin spending
  somebody else's money; the second stops an owner pointing their money at a project they have
  nothing to do with.

  Tickets stuck because no credential could fund their job are brought back, since this may be
  what they were waiting for.
  """
  @spec assign(User.t(), String.t(), String.t()) ::
          {:ok, ProjectCredential.t()}
          | {:error, :not_found | :not_a_member | Ecto.Changeset.t()}
  def assign(%User{} = user, credential_id, project_id) do
    with %Credential{revoked_at: nil} = credential <- get(user, credential_id),
         :ok <- member(user, project_id) do
      Multi.new()
      |> Multi.insert(
        :assignment,
        ProjectCredential.changeset(%ProjectCredential{}, %{
          project_id: project_id,
          credential_id: credential.id
        })
      )
      |> Events.log(:event, "credential.assigned", {:user, user.id}, %{
        project_id: project_id,
        payload: Map.put(describe(credential), "project_id", project_id)
      })
      |> Repo.transaction()
      |> case do
        {:ok, %{assignment: assignment}} ->
          Engine.resume_placement(project_id, {:user, user.id})
          {:ok, assignment}

        {:error, :assignment, changeset, _changes} ->
          {:error, changeset}
      end
    else
      {:error, :not_a_member} -> {:error, :not_a_member}
      _missing_or_revoked -> {:error, :not_found}
    end
  end

  @doc "Takes a credential out of a project's pool. The owner's, and only for a project they are in."
  @spec unassign(User.t(), String.t(), String.t()) :: :ok | {:error, :not_found | :not_a_member}
  def unassign(%User{} = user, credential_id, project_id) do
    with %Credential{} = credential <- get(user, credential_id),
         :ok <- member(user, project_id) do
      Multi.new()
      |> Multi.delete_all(
        :assignment,
        from(a in ProjectCredential,
          where: a.credential_id == ^credential.id and a.project_id == ^project_id
        )
      )
      |> Events.log(:event, "credential.unassigned", {:user, user.id}, %{
        project_id: project_id,
        payload: Map.put(describe(credential), "project_id", project_id)
      })
      |> Repo.transaction()

      :ok
    else
      {:error, :not_a_member} -> {:error, :not_a_member}
      nil -> {:error, :not_found}
    end
  end

  @doc "The projects this credential funds, by name."
  @spec projects(Credential.t()) :: [Forge.Projects.Project.t()]
  def projects(%Credential{id: id}) do
    Repo.all(
      from p in Forge.Projects.Project,
        join: a in ProjectCredential,
        on: a.project_id == p.id,
        where: a.credential_id == ^id,
        order_by: p.name
    )
  end

  @doc """
  A project's pool for one harness: its assigned credentials that are not revoked, oldest first.

  **Revoked is filtered here and nowhere else**, so a revocation reaches every job that has not
  started yet and every job that starts again, on the next pass. Its assignments are left in
  place as history of what the credential funded.
  """
  @spec pool(String.t(), String.t()) :: [Credential.t()]
  def pool(project_id, harness) do
    Repo.all(
      from c in Credential,
        join: a in ProjectCredential,
        on: a.credential_id == c.id,
        where: a.project_id == ^project_id and c.harness == ^harness and is_nil(c.revoked_at),
        order_by: [asc: c.inserted_at, asc: c.id]
    )
  end

  @doc """
  The credential `job` runs on (`docs/design/credentials.md` § How a job picks).

  **At a job's first start**, from its project's pool: drop the credentials that are rate-limited
  now, and of the rest take the one that has spent least today — the oldest on a tie, which is
  the pool's order. Everything limited is `{:limited, until}`, the earliest reset: the job waits,
  and nobody is being asked to do anything.

  **At every later start it keeps the one it is on** while that is still in the pool and not
  limited — a resumed session keeps the account whose prompt cache it built. Limited, it picks
  again by the same rule, which moves it to a free credential or, with none free, answers
  `{:limited, until}` for the earliest reset of them all; revoked or taken out of the project, it
  picks again. `Forge.Jobs` records a move as `job.credential_changed`, and the job's spend
  follows its runs, each on its own credential (`Forge.Jobs.Runs`).
  """
  @spec for_job(Job.t(), DateTime.t()) ::
          {:ok, Credential.t()}
          | {:error, {:no_credential, :none_assigned} | {:limited, DateTime.t()}}
  def for_job(%Job{} = job, now \\ DateTime.utc_now()) do
    pool = pool(job.project_id, Forge.Jobs.harness(job))
    limited = limited(Enum.map(pool, & &1.id), now)

    case Enum.find(pool, &(&1.id == job.credential_id)) do
      %Credential{id: id} = kept when not is_map_key(limited, id) -> {:ok, kept}
      _limited_or_unusable -> pick(pool, limited, DateTime.to_date(now))
    end
  end

  defp pick([], _limited, _today), do: {:error, {:no_credential, :none_assigned}}

  defp pick(pool, limited, today) do
    case Enum.reject(pool, &Map.has_key?(limited, &1.id)) do
      [] ->
        {:error, {:limited, limited |> Map.values() |> Enum.min(DateTime)}}

      free ->
        spent = spent_today(Enum.map(free, & &1.id), today)
        {:ok, Enum.min_by(free, &Map.get(spent, &1.id, Decimal.new(0)), Decimal)}
    end
  end

  @doc """
  What each of these credentials has spent today, in UTC, by id: the sum of `cost_usd` over the
  runs that spent it and *started* today (`docs/design/credentials.md` § Spend). Over runs and not
  jobs, because a job may move between credentials and each run spent only its own.

  The day and the rows are `Forge.Spend.day_total/1`'s, so a credential's figure and the node's
  add up. A credential that has spent nothing is absent rather than zero.
  """
  @spec spent_today([String.t()], Date.t()) :: %{String.t() => Decimal.t()}
  def spent_today(ids, date \\ Date.utc_today()) do
    {from_time, until} = Spend.day(date)

    Repo.all(
      from r in Run,
        where: r.credential_id in ^ids and r.started_at >= ^from_time and r.started_at < ^until,
        group_by: r.credential_id,
        select: {r.credential_id, sum(r.cost_usd)}
    )
    |> Map.new()
  end

  @doc """
  The credentials among these that are rate-limited at `now`, each with when it is free again:
  the latest reset among its windows that block, since it is free only once all of them have
  (`docs/design/credentials.md` § Rate limits are per credential).
  """
  @spec limited([String.t()], DateTime.t()) :: %{String.t() => DateTime.t()}
  def limited(ids, now \\ DateTime.utc_now()) do
    for {id, windows} <- windows(ids, now),
        blocking = for({_type, %{limited: true, resets_at: at}} <- windows, do: at),
        blocking != [],
        into: %{},
        do: {id, Enum.max(blocking, DateTime)}
  end

  # Where window reports come from. The harness's own, stamped as they arrive; and the platform's
  # record of a run its limit stopped, which carries the same fields under the same stamp because
  # the timeline's copy is unacked — lost, it would leave the pick believing the credential free
  # and sending the job straight back to it.
  @reports ["job.harness.rate_limit", "job.rate_limited"]

  # The windows the top bar draws. Others — a model's own weekly limit, say — still block a pick;
  # they are on each credential's row, and not in a gauge built for two.
  @gauged ["five_hour", "seven_day"]

  @doc """
  When one window report stops blocking, if it blocks at `now` — read by exactly the rule
  `windows/2` reads a credential's reports by. For a run's own last report, which is how
  `Forge.Jobs.complete/2` tells a run its limit stopped from one that failed
  (`docs/design/credentials.md` § A limit reached mid-run).
  """
  @spec blocks_until(map() | nil, DateTime.t()) :: DateTime.t() | nil
  def blocks_until(%{} = report, now) do
    case open(type(report), window(report), now) do
      [{_type, %{limited: true, resets_at: until}}] -> until
      _permits -> nil
    end
  end

  def blocks_until(_absent, _now), do: nil

  @doc """
  Each credential's current windows, by `rate_limit_type`: its utilization when the provider gave
  one, when it resets, and whether it blocks. A credential with none known is absent, and so is a
  window whose reset has passed — it rolled over, and nothing is known about the new one
  (`docs/design/capacity.md` § Engine support).

  **A window is its own latest report.** Each report names one type, and one about the five-hour
  window says nothing about the week, so they are read per credential *and* type. Whether one
  blocks is its report's alone: a status beginning `allowed` permits and anything else blocks
  until the reset; a report with no reset has no end to wait for and blocks nothing.

  **`windows` in a report** — `unifiedWindows`, which newer releases are reported to send — gives
  every window's utilization and reset. Where the credential's newest report carries it, it is
  the newer figure for each window it names, and never decides whether one blocks: it carries no
  status.
  """
  @spec windows([String.t()], DateTime.t()) :: %{String.t() => %{String.t() => map()}}
  def windows(ids, now \\ DateTime.utc_now()) do
    Repo.all(
      from e in Event,
        where: e.type in @reports and fragment("?->>'credential_id'", e.payload) in ^ids,
        distinct: [
          fragment("?->>'credential_id'", e.payload),
          fragment("?->>'rate_limit_type'", e.payload)
        ],
        order_by: [desc: e.seq],
        select: {e.seq, e.payload}
    )
    |> Enum.group_by(fn {_seq, payload} -> payload["credential_id"] end)
    |> Enum.flat_map(fn {id, reports} ->
      case current(reports, now) do
        empty when map_size(empty) == 0 -> []
        windows -> [{id, windows}]
      end
    end)
    |> Map.new()
  end

  @doc """
  The top bar's gauge over these credentials, per window drawn — five-hour and weekly
  (`docs/design/credentials.md` § Showing the windows):

    * `mean` — the mean utilization of the credentials that reported one, a limited credential
      counting as full; `nil` when none did, and then there is no gauge to draw.
    * `reporting` of `known` — how many of those with a current window of the kind gave a
      figure, which is what the mean is over.
    * `soonest` — the earliest reset among them, which the countdown is to.

  A window no credential has a current report of is absent: there is nothing truthful to draw.
  """
  @spec gauge([String.t()], DateTime.t()) :: %{String.t() => map()}
  def gauge(ids, now \\ DateTime.utc_now()) do
    windows = ids |> windows(now) |> Map.values()

    for type <- @gauged,
        known = for(%{^type => window} <- windows, do: window),
        known != [],
        into: %{} do
      figures = for window <- known, figure = figure(window), do: figure

      {type,
       %{
         mean: if(figures == [], do: nil, else: Enum.sum(figures) / length(figures)),
         reporting: length(figures),
         known: length(known),
         soonest: known |> Enum.map(& &1.resets_at) |> Enum.min(DateTime)
       }}
    end
  end

  # A limited window is full whatever it last said. A figure outside 0..1 is the worker's and is
  # drawn as the nearest end rather than as a gauge that overflows.
  defp figure(%{limited: true}), do: 1.0
  defp figure(%{utilization: u}) when is_number(u), do: u |> max(0) |> min(1) |> Kernel.*(1.0)
  defp figure(_unreported), do: nil

  @doc "The ids of this user's live credentials — what the top bar draws away from a project."
  @spec owned_ids(User.t()) :: [String.t()]
  def owned_ids(%User{id: user_id}) do
    Repo.all(
      from c in Credential, where: c.user_id == ^user_id and is_nil(c.revoked_at), select: c.id
    )
  end

  @doc """
  The ids of the live credentials in a project's pool, whatever their harness — what the top bar
  draws on a page about that project. The caller has already decided the viewer may see the
  project; this reads nothing about who is asking.
  """
  @spec pool_ids(String.t()) :: [String.t()]
  def pool_ids(project_id) do
    Repo.all(
      from c in Credential,
        join: a in ProjectCredential,
        on: a.credential_id == c.id,
        where: a.project_id == ^project_id and is_nil(c.revoked_at),
        select: c.id
    )
  end

  # Every field here is the worker's: a `windows` that is not an object has none, and a
  # utilization that is not a number is no figure. A report whose type is missing or not a string
  # is a window of type `"unknown"` rather than no window at all, so that a blocking report still
  # blocks — the rule fails towards not spending (`docs/design/capacity.md` § Engine support).
  defp current(reports, now) do
    {_seq, newest} = Enum.max_by(reports, fn {seq, _payload} -> seq end)

    own =
      reports
      |> Enum.sort_by(fn {seq, _payload} -> seq end)
      |> Map.new(fn {_seq, report} -> {type(report), window(report)} end)

    unified =
      for {type, %{} = figures} <- objects(newest["windows"]), into: %{} do
        {type,
         %{
           utilization: fraction(figures["utilization"]),
           resets_at: at(figures["resets_at"]),
           limited: false
         }}
      end

    # The newest report's figures are at least as new as any window's own report. A window that
    # blocks keeps its own reset, which is what it blocks until.
    own
    |> Map.merge(unified, fn
      _type, %{limited: true} = own, newer -> %{own | utilization: newer.utilization}
      _type, _own, newer -> newer
    end)
    |> Enum.flat_map(fn {type, window} -> open(type, window, now) end)
    |> Map.new()
  end

  defp type(%{"rate_limit_type" => type}) when is_binary(type), do: type
  defp type(_report), do: "unknown"

  defp objects(%{} = map), do: map
  defp objects(_other), do: %{}

  defp fraction(value) when is_number(value), do: value
  defp fraction(_other), do: nil

  defp window(report) do
    %{
      utilization: fraction(report["utilization"]),
      resets_at: at(report["resets_at"]),
      limited: blocks?(report["status"])
    }
  end

  # Only a window still ahead of its reset is current, so this is where "until the reset" is
  # enforced for blocking too. One past it rolled over and nothing is known about the next; one
  # with no reset has no end, and a job waiting on it would be waiting on nothing.
  defp open(type, %{resets_at: %DateTime{} = at} = window, now) do
    if DateTime.compare(at, now) == :gt, do: [{type, window}], else: []
  end

  defp open(_type, _window, _now), do: []

  defp blocks?(status) when is_binary(status), do: not String.starts_with?(status, "allowed")
  defp blocks?(_status), do: false

  # `resets_at` is the worker's integer, and `DateTime.from_unix!/1` raises on one outside the
  # calendar: a single report like that would crash every scheduler pass that read it, so it is a
  # report that says nothing, like one without a reset at all.
  defp at(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, at} -> at
      {:error, _outside} -> nil
    end
  end

  defp at(_absent), do: nil

  @doc """
  The credential as the worker receives it: harness, kind, and the secret sealed for that worker
  and that job (`ForgeCore.Job.Credential`). The Vault is opened and the secret sealed again in
  this one function, so the plaintext is never in an assignment, a message or a process state.
  """
  @spec for_wire(Credential.t(), Worker.t(), String.t()) :: {:ok, map()} | {:error, :unreadable}
  def for_wire(%Credential{id: id} = credential, %Worker{token_hash: token_hash}, job_id) do
    sealed = Repo.one(from c in Credential, where: c.id == ^id, select: c.secret)

    case Credential.open(sealed) do
      {:ok, %{"token" => secret}} ->
        {:ok,
         %{
           "harness" => credential.harness,
           "kind" => credential.kind,
           "sealed" => ForgeCore.Job.Credential.seal(secret, token_hash, job_id)
         }}

      _unreadable ->
        {:error, :unreadable}
    end
  end

  @doc """
  The models the credentials in a project's pool may use, each once — what a model picker for
  that project offers (`docs/design/credentials.md` § Checked on save). None for no project.
  """
  @spec models(String.t() | nil) :: [%{id: String.t(), name: String.t()}]
  def models(nil), do: []

  def models(project_id) do
    Repo.all(
      from c in Credential,
        join: a in ProjectCredential,
        on: a.credential_id == c.id,
        where: a.project_id == ^project_id and is_nil(c.revoked_at),
        select: c.models
    )
    |> Enum.flat_map(&(&1 || []))
    |> Enum.flat_map(fn
      %{"id" => id} = model when is_binary(id) -> [%{id: id, name: model["name"] || id}]
      _other -> []
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp member(%User{} = user, project_id) do
    with {:ok, id} <- Ecto.UUID.cast(project_id),
         role when not is_nil(role) <- Projects.role(%Forge.Projects.Project{id: id}, user) do
      :ok
    else
      _not_a_member -> {:error, :not_a_member}
    end
  end

  @doc "Whether this credential has been revoked."
  @spec revoked?(Credential.t()) :: boolean()
  def revoked?(%Credential{revoked_at: revoked_at}), do: not is_nil(revoked_at)

  # What the event log may say about a credential: which one, never what it is.
  defp describe(%Credential{} = c),
    do: %{"credential_id" => c.id, "name" => c.name, "harness" => c.harness, "kind" => c.kind}

  defp cast_id(nil), do: :error
  defp cast_id(id), do: Ecto.UUID.cast(id)

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  defp now, do: DateTime.utc_now(:second)
end
