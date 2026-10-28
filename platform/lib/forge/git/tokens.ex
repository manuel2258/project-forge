defmodule Forge.Git.Tokens do
  @moduledoc """
  Issuing, authorising and revoking the credentials the git endpoint accepts.

  A token is shown once, at issue, and stored only as a sha256 hash. Authorisation looks a token
  up **by hash**, so the index does the matching and no secret is ever compared as a string; the
  constant-time comparison that follows is belt and braces.

  See `docs/design/git-hosting.md`.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Git.Token
  alias Forge.Jobs.Job
  alias Forge.Projects.Project
  alias Forge.Repo
  alias Forge.Tickets.Ticket

  @rand_size 32
  @max_days 365
  @default_ttl_minutes 90

  @typedoc "What a request needs: reading advertises and fetches, writing pushes."
  @type capability :: :read | :write

  @doc """
  Issues a token for `project`. Returns the secret, which is never recoverable afterwards.

  Options: `:name` (required unless a job holds it), `:git` (`:none`, `:reader`, `:branch`,
  `:developer`, `:admin`; default `:branch` when a `:ref` is given, else `:reader`), `:api`
  (`:none`, `:read`, `:write`; default `:none`), `:issued_by_id`, `:ticket_id`, `:job_id`, `:ref`
  (required for `:branch`), and the lifetime: `:days` (1..#{@max_days}, for a person's token) or
  `:ttl_minutes` (a job's, and the default).

  What a `:ref` may name is `Forge.Git.Token`'s to say, and it is said against this project's
  default branch: the operator's default-branch token is mintable here and a job's is not.
  """
  @spec issue(Project.t(), keyword()) :: {:ok, String.t(), Token.t()} | {:error, term()}
  def issue(%Project{} = project, opts \\ []) do
    secret = :crypto.strong_rand_bytes(@rand_size)
    ref = Keyword.get(opts, :ref)

    attrs = %{
      token_hash: hash(secret),
      project_id: project.id,
      ticket_id: Keyword.get(opts, :ticket_id),
      job_id: Keyword.get(opts, :job_id),
      ref: ref,
      name: Keyword.get(opts, :name),
      git_access: Keyword.get(opts, :git, if(ref, do: :branch, else: :reader)),
      api_access: Keyword.get(opts, :api, :none),
      issued_by_id: Keyword.get(opts, :issued_by_id)
    }

    with {:ok, minutes} <- lifetime_minutes(opts),
         attrs =
           Map.put(
             attrs,
             :expires_at,
             DateTime.add(DateTime.utc_now(:second), minutes * 60, :second)
           ),
         {:ok, token} <-
           Repo.insert(Token.create_changeset(%Token{}, attrs, project.default_branch)) do
      {:ok, Base.url_encode64(secret, padding: false), token}
    end
  end

  # A person's lifetime is days, and bounded here so the page and the mix task share the bound; a
  # job's is minutes and the engine's. Both given, or minutes below one, is a caller's mistake worth
  # failing on.
  defp lifetime_minutes(opts) do
    case {Keyword.get(opts, :days), Keyword.get(opts, :ttl_minutes)} do
      {nil, nil} ->
        {:ok, ttl_minutes()}

      # A job's minutes are the engine's. A person's are bounded by the same year as their days,
      # or `mix forge.git.token --minutes` would be a way round the ceiling.
      {nil, minutes} when is_integer(minutes) and minutes >= 1 ->
        job_minutes(minutes, Keyword.get(opts, :job_id))

      {days, nil} when is_integer(days) and days >= 1 and days <= @max_days ->
        {:ok, days * 24 * 60}

      _other ->
        {:error, {:bad_days, @max_days}}
    end
  end

  defp job_minutes(minutes, nil) when minutes > @max_days * 24 * 60,
    do: {:error, {:bad_days, @max_days}}

  defp job_minutes(minutes, _job_id), do: {:ok, minutes}

  @doc "The longest lifetime, in days, a person's token may be issued for."
  @spec max_days() :: pos_integer()
  def max_days, do: @max_days

  @doc """
  The ref an operator's default-branch token is minted for: the one shape that may write what
  every job builds on, and the reason there is no SSH route into a repository.

  Fast-forward only, because `priv/git-hooks/pre-receive` says so of every writer of that branch,
  the platform's own merge included. No job is issued it — `Forge.Git.Token` refuses.
  """
  @spec default_ref(Project.t()) :: String.t()
  def default_ref(%Project{default_branch: branch}), do: "refs/heads/" <> branch

  @doc """
  Issues the token a job works with: for an agent, a write token scoped to the project, the ticket
  and its branch; for a command, a read-only one.

  A conversation gets one scoped to `chat/<id>` and to no ticket — its work goes to its own
  branch, never the ticket's, so a token that could write the ticket's branch would be a token
  wider than anything it is for (`docs/design/conversations.md` § Commits).
  """
  @spec issue_for_job(Job.t(), Ticket.t() | nil, Project.t()) ::
          {:ok, String.t(), Token.t()} | {:error, term()}
  def issue_for_job(%Job{kind: :chat} = job, _ticket, %Project{} = project) do
    issue(project,
      job_id: job.id,
      ref: "refs/heads/" <> Forge.Jobs.chat_branch(job),
      git: :branch,
      ttl_minutes: job_ttl_minutes(job)
    )
  end

  # A command reads its commit and writes nothing: its token carries no ref and no write
  # (`docs/design/commands.md` § How a command gets the code).
  def issue_for_job(%Job{kind: :command} = job, %Ticket{} = ticket, %Project{} = project) do
    issue(project,
      ticket_id: ticket.id,
      job_id: job.id,
      git: :reader,
      ttl_minutes: job_ttl_minutes(job)
    )
  end

  def issue_for_job(%Job{} = job, %Ticket{} = ticket, %Project{} = project) do
    issue(project,
      ticket_id: ticket.id,
      job_id: job.id,
      ref: "refs/heads/" <> ticket.branch,
      git: :branch,
      ttl_minutes: job_ttl_minutes(job)
    )
  end

  # **The job's wall clock plus a margin** (`docs/design/git-hosting.md` § The per-job token). A
  # conversation pushes after every turn for up to a day, and a token of the fixed ninety
  # minutes refused every push after the first hour and a half — each turn's commit lost with
  # nothing but a warning on the worker. The margin is the configured lifetime, which is what
  # every token had before, so a workflow job's is never shorter than it was.
  defp job_ttl_minutes(job), do: div(Forge.Jobs.wall_clock_ms(job), 60_000) + ttl_minutes()

  @doc """
  Resolves a presented secret to a live token with at least `needs` on `project`.

  Fails identically — `:error` — for a malformed, unknown, expired, revoked, wrong-project or
  under-powered credential, so a caller cannot learn which.
  """
  @spec authorise(String.t() | nil, Project.t(), capability()) :: {:ok, Token.t()} | :error
  def authorise(secret, project, needs)

  def authorise(secret, %Project{} = project, needs) when is_binary(secret) do
    with {:ok, token} <- find(secret),
         true <- live?(token),
         true <- token.project_id == project.id,
         true <- permits?(token.git_access, needs) do
      touch(token, :git)
      {:ok, token}
    else
      _other -> :error
    end
  end

  def authorise(_secret, _project, _needs), do: :error

  defp permits?(:none, _needs), do: false
  defp permits?(_access, :read), do: true
  defp permits?(access, :write), do: access in [:branch, :developer, :admin]

  @doc """
  Resolves a presented secret to the project token it is, for the JSON API.

  Only a token nobody's job holds, with API access, that is live. `:error` for every other reason
  — unknown, expired, revoked, a job's, git-only — so the 401 says nothing about which.
  """
  @spec authenticate_api(String.t() | nil) :: {:ok, Token.t()} | :error
  def authenticate_api(secret) when is_binary(secret) do
    with {:ok, token} <- find(secret),
         true <- live?(token),
         nil <- token.job_id,
         true <- token.api_access != :none do
      touch(token, :api)
      {:ok, token}
    else
      _other -> :error
    end
  end

  def authenticate_api(_secret), do: :error

  @doc """
  Resolves a presented secret to a live token **a job holds** — the grant the archive door takes
  (`docs/design/archive.md`). An operator's token has no job and is refused, as is every other
  failure, identically: `:error`.
  """
  @spec authorise_job(String.t() | nil) :: {:ok, Token.t()} | :error
  def authorise_job(secret) when is_binary(secret) do
    with {:ok, token} <- find(secret),
         true <- live?(token),
         true <- is_binary(token.job_id) do
      touch(token, :archive)
      {:ok, token}
    else
      _other -> :error
    end
  end

  def authorise_job(_secret), do: :error

  # The row a presented secret names. Found by its hash, so the index does the matching; the
  # comparison after it is an equivalent mutant (the row was selected by that very equality) kept as
  # the belt and braces the moduledoc describes, and no test can make the two disagree.
  defp find(secret) do
    with {:ok, raw} <- Base.url_decode64(secret, padding: false),
         %Token{} = token <- Repo.one(from t in Token, where: t.token_hash == ^hash(raw)),
         true <- Plug.Crypto.secure_compare(token.token_hash, hash(raw)) do
      {:ok, token}
    end
  end

  @doc """
  The refs the git door lets this token write, which `priv/git-hooks/pre-receive` receives as
  `FORGE_ALLOWED_REFS`: the one branch of a `branch` token, every open ticket's branch for a
  developer, and those plus the default branch for an admin. A reader, and a token with no git
  access, has none. A conversation's branch is in no list: only the token its own job holds
  names it.
  """
  @spec allowed_refs(Token.t(), Project.t()) :: [String.t()]
  def allowed_refs(%Token{git_access: :branch, ref: ref}, _project), do: [ref]
  def allowed_refs(%Token{git_access: :developer}, project), do: open_branches(project)

  def allowed_refs(%Token{git_access: :admin}, project),
    do: open_branches(project) ++ [default_ref(project)]

  def allowed_refs(%Token{}, _project), do: []

  defp open_branches(%Project{id: id}) do
    Repo.all(
      from t in Ticket,
        where: t.project_id == ^id and t.status in ^Ticket.open_statuses(),
        order_by: t.number,
        select: fragment("'refs/heads/' || ?", t.branch)
    )
  end

  @doc "Revokes every live token issued for `job_id`. Rows are kept: they are the audit trail."
  @spec revoke_for_job(String.t()) :: non_neg_integer()
  def revoke_for_job(job_id) do
    now = DateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(t in Token, where: t.job_id == ^job_id and is_nil(t.revoked_at)),
        set: [revoked_at: now]
      )

    count
  end

  @doc "Adds `revoke_for_job/1` to `multi`, for a revocation that belongs to a transaction."
  @spec put_revoke_for_job(Multi.t(), term(), String.t()) :: Multi.t()
  def put_revoke_for_job(multi, key, job_id) do
    Multi.run(multi, key, fn _repo, _changes -> {:ok, revoke_for_job(job_id)} end)
  end

  @doc """
  Every token ever issued for `project`, newest first.

  The secret is not among them and cannot be: only its hash is kept. A row says what a token may
  do and whether it has been used, which is what an audit trail is for.
  """
  @spec list(Project.t()) :: [Token.t()]
  def list(%Project{id: project_id}) do
    Repo.all(
      from t in Token,
        where: t.project_id == ^project_id,
        order_by: [desc: t.inserted_at],
        preload: :issued_by
    )
  end

  @doc """
  Revokes one token by id. The row is kept — it is the record that it existed.

  Refuses a token a job holds: the engine revokes those when the job ends, and revoking one
  mid-run fails that job for a reason nothing would record. See `docs/design/git-hosting.md`.
  """
  @spec revoke(String.t()) :: {:ok, Token.t()} | {:error, :not_found | :held_by_job}
  def revoke(id) do
    case Repo.get(Token, id) do
      nil ->
        {:error, :not_found}

      %Token{job_id: job_id} when is_binary(job_id) ->
        {:error, :held_by_job}

      token ->
        {:ok, Repo.update!(Ecto.Changeset.change(token, revoked_at: DateTime.utc_now(:second)))}
    end
  end

  @doc "Whether this token can still authorise anything."
  @spec live?(Token.t(), DateTime.t()) :: boolean()
  def live?(%Token{revoked_at: nil, expires_at: expires_at}, now),
    do: DateTime.after?(expires_at, now)

  def live?(%Token{}, _now), do: false

  @doc """
  Deletes a job's tokens that expired more than a day ago. Nothing calls this on a timer yet.

  A token a person issued is not swept: its row is the audit record, and the author an answer or
  a version it wrote names (`docs/design/git-hosting.md` § One project token, two doors).
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    cutoff = DateTime.add(DateTime.utc_now(:second), -86_400, :second)

    {count, _} =
      Repo.delete_all(from t in Token, where: t.expires_at < ^cutoff and not is_nil(t.job_id))

    count
  end

  @doc "The configured token lifetime in minutes."
  @spec ttl_minutes() :: pos_integer()
  def ttl_minutes, do: Forge.Jobs.config(:git_token_ttl_minutes, @default_ttl_minutes)

  defp hash(raw), do: :crypto.hash(:sha256, raw)

  defp live?(%Token{revoked_at: nil, expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp live?(%Token{}), do: false

  # Off the request path: a credential that works must not wait on a write.
  defp touch(%Token{id: id}, via) do
    Task.Supervisor.start_child(Forge.TaskSupervisor, fn ->
      Repo.update_all(from(t in Token, where: t.id == ^id),
        set: [last_used_at: DateTime.utc_now(:second), last_used_via: via]
      )
    end)

    :ok
  end
end
