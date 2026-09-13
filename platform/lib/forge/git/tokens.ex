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
  @default_ttl_minutes 90

  @typedoc "What a request needs: reading advertises and fetches, writing pushes."
  @type capability :: :read | :write

  @doc """
  Issues a token for `project`. Returns the secret, which is never recoverable afterwards.

  Options: `:ticket_id`, `:job_id`, `:ref` (required when writing), `:write`, `:ttl_minutes`.
  """
  @spec issue(Project.t(), keyword()) :: {:ok, String.t(), Token.t()} | {:error, term()}
  def issue(%Project{} = project, opts \\ []) do
    secret = :crypto.strong_rand_bytes(@rand_size)
    ttl = Keyword.get(opts, :ttl_minutes, ttl_minutes())

    attrs = %{
      token_hash: hash(secret),
      project_id: project.id,
      ticket_id: Keyword.get(opts, :ticket_id),
      job_id: Keyword.get(opts, :job_id),
      ref: Keyword.get(opts, :ref),
      write: Keyword.get(opts, :write, false),
      expires_at: DateTime.add(DateTime.utc_now(:second), ttl * 60, :second)
    }

    with {:ok, token} <- Repo.insert(Token.create_changeset(%Token{}, attrs)) do
      {:ok, Base.url_encode64(secret, padding: false), token}
    end
  end

  @doc """
  Issues the write token a job works with: scoped to the project, the ticket and its branch.
  """
  @spec issue_for_job(Job.t(), Ticket.t(), Project.t()) ::
          {:ok, String.t(), Token.t()} | {:error, term()}
  def issue_for_job(%Job{} = job, %Ticket{} = ticket, %Project{} = project) do
    issue(project,
      ticket_id: ticket.id,
      job_id: job.id,
      ref: "refs/heads/" <> ticket.branch,
      write: true
    )
  end

  @doc """
  Resolves a presented secret to a live token with at least `needs` on `project`.

  Fails identically — `:error` — for a malformed, unknown, expired, revoked, wrong-project or
  under-powered credential, so a caller cannot learn which.
  """
  @spec authorise(String.t() | nil, Project.t(), capability()) :: {:ok, Token.t()} | :error
  def authorise(secret, project, needs)

  def authorise(secret, %Project{} = project, needs) when is_binary(secret) do
    with {:ok, raw} <- Base.url_decode64(secret, padding: false),
         %Token{} = token <- Repo.one(from t in Token, where: t.token_hash == ^hash(raw)),
         true <- Plug.Crypto.secure_compare(token.token_hash, hash(raw)),
         true <- live?(token),
         true <- token.project_id == project.id,
         true <- needs != :write or token.write do
      touch(token)
      {:ok, token}
    else
      _other -> :error
    end
  end

  def authorise(_secret, _project, _needs), do: :error

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

  @doc "Deletes tokens that expired more than a day ago. Nothing calls this on a timer yet."
  @spec sweep() :: non_neg_integer()
  def sweep do
    cutoff = DateTime.add(DateTime.utc_now(:second), -86_400, :second)
    {count, _} = Repo.delete_all(from t in Token, where: t.expires_at < ^cutoff)
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
  defp touch(%Token{id: id}) do
    Task.Supervisor.start_child(Forge.TaskSupervisor, fn ->
      Repo.update_all(from(t in Token, where: t.id == ^id),
        set: [last_used_at: DateTime.utc_now(:second)]
      )
    end)

    :ok
  end
end
