defmodule Forge.Git.Token do
  @moduledoc """
  A credential for a project: its git endpoint and, when it is not a job's, its JSON API.

  Not a user token: it has no user, its scope is a project rather than an account, and a job's
  lifetime is the job rather than "until revoked". Only the mechanics are shared with
  `Forge.Accounts.UserToken` — 32 random bytes handed out once, a sha256 hash stored.

  `git_access` is what the git door allows (`none`, `reader`, `branch`, `developer`, `admin`) and
  `api_access` what the API door does (`none`, `read`, `write`). `ref` is the one ref a `branch`
  token may update: `refs/heads/ticket/<n>` for a ticket's job, `refs/heads/chat/<uuid>` for a
  conversation, or the project's default branch for the token an operator minted by hand before
  `admin` existed. No other access has one.
  See `docs/design/git-hosting.md` and `docs/design/conversations.md` § Commits.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @uuid "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @write_ref ~r{^refs/heads/(ticket/\d+|chat/#{@uuid})$}

  @name_max 60

  @type t :: %__MODULE__{}

  @doc "The longest name a hand-minted token may have."
  def name_max, do: @name_max

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "git_tokens" do
    field :token_hash, :binary, redact: true
    field :ref, :string
    field :name, :string

    field :git_access, Ecto.Enum,
      values: [:none, :reader, :branch, :developer, :admin],
      default: :reader

    field :api_access, Ecto.Enum, values: [:none, :read, :write], default: :none
    field :last_used_via, Ecto.Enum, values: [:git, :api, :archive]
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :project, Forge.Projects.Project
    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :job, Forge.Jobs.Job
    belongs_to :issued_by, Forge.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  The changeset every token is minted through.

  `default_branch` is the project's, and this is the only place that knows a ref naming it is
  mintable at all: the shape is per-project, so it cannot live in a module attribute the way the
  ticket and chat namespaces do. It must agree with `forge.defaultBranch` in the repository, which
  `Forge.Git.Hooks.install/2` writes from the same column.
  """
  def create_changeset(token, attrs, default_branch) do
    token
    |> cast(attrs, [
      :token_hash,
      :project_id,
      :ticket_id,
      :job_id,
      :ref,
      :name,
      :git_access,
      :api_access,
      :issued_by_id,
      :expires_at
    ])
    |> validate_required([:token_hash, :project_id, :expires_at, :git_access, :api_access])
    |> validate_ref(default_branch)
    |> validate_job_or_hand_minted()
    |> validate_not_a_job_on_the_default_branch(default_branch)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:job_id)
    |> foreign_key_constraint(:issued_by_id)
    |> unique_constraint(:token_hash)
  end

  # A job's token never opens the API, and is at most one branch. Without the first the lookup
  # `Tokens.authenticate_api/1` refuses a job's token anyway; the two say the same thing so that
  # neither is the only thing between a running job and the API. A hand-minted token is a
  # person's: it has a name to be audited by, and allows something.
  defp validate_job_or_hand_minted(changeset) do
    if get_field(changeset, :job_id) do
      changeset
      |> validate_inclusion(:git_access, [:reader, :branch],
        message: "a job's token is a reader or one branch"
      )
      |> validate_inclusion(:api_access, [:none], message: "a job's token never opens the API")
    else
      changeset
      |> validate_required(:name, message: "is required")
      |> validate_length(:name, max: @name_max)
      |> validate_allows_something()
    end
  end

  defp validate_allows_something(changeset) do
    if get_field(changeset, :git_access) == :none and get_field(changeset, :api_access) == :none do
      add_error(changeset, :git_access, "allows nothing: choose git access, API access or both")
    else
      changeset
    end
  end

  # A branch token without a ref would be a credential for the whole repository, which is the one
  # thing the branch discipline exists to prevent. Any other access names none: the hook decides
  # what a developer or an admin may write from the project's open tickets, not from a column.
  defp validate_ref(changeset, default_branch) do
    case {get_field(changeset, :git_access), get_field(changeset, :ref)} do
      {:branch, nil} ->
        add_error(changeset, :ref, "is required for a branch token")

      {:branch, ref} ->
        # The same namespaces `priv/git-hooks/pre-receive` accepts, and for the same reason: a
        # token wider than one branch is a token that can write someone else's work. Ticket and
        # chat are matched to their shape rather than to a glob; the default branch is matched
        # against the project's own rather than a pattern, because `main` is only privileged
        # where it is the default. The hook is the enforcement point and this is what may be
        # minted, so the two have to agree.
        if default?(ref, default_branch) do
          changeset
        else
          validate_format(changeset, :ref, @write_ref,
            message:
              "must be refs/heads/ticket/<number>, refs/heads/chat/<id> or refs/heads/" <>
                (default_branch || "<default branch>")
          )
        end

      {_other, nil} ->
        changeset

      {_other, _ref} ->
        add_error(changeset, :ref, "only a branch token names a ref")
    end
  end

  # The default-branch token is an operator's, minted by hand (the mix task's `--default`, and
  # `Forge.Release`; the settings page mints `admin` now).
  # A job's is issued by the engine for the branch that job works on, and `Tokens.issue_for_job/3`
  # asks for nothing else — this is the guard that says so at the point of minting, so the
  # property "no credential a job holds can move the default branch" does not rest on every
  # caller remembering it. See `docs/design/git-hosting.md` § The default-branch token.
  defp validate_not_a_job_on_the_default_branch(changeset, default_branch) do
    if get_field(changeset, :job_id) && default?(get_field(changeset, :ref), default_branch) do
      add_error(changeset, :ref, "a job is never given the default branch")
    else
      changeset
    end
  end

  defp default?(ref, branch) when is_binary(ref) and is_binary(branch),
    do: ref == "refs/heads/" <> branch

  defp default?(_ref, _branch), do: false
end
