defmodule Forge.Access do
  @moduledoc """
  What a person may do, asked as a capability rather than compared as a role name.

  `docs/design/identity.md` § The capability seam. Two roles today expand into two
  capabilities, which looks like indirection for nothing until the roles split — and then it is
  one function to change instead of every call site. Callers never see `:admin`.

  - `:use` — everything the product does on a project: admit tickets, answer questions, approve
    transitions and merges, edit documents, open conversations, decide proposals.
  - `:manage` — the project's own settings, its deletion, and who is in it.

  Node admins are **not** privileged here and this is the point of them: the flag governs
  accounts, not work. A node admin who is not a member of a project reaches nothing in it.
  """

  alias Forge.Accounts.Scope
  alias Forge.Projects.Member

  @type capability :: :use | :manage

  @doc """
  Whether the scope carries `capability` on the project it was resolved for.

  A scope with no membership answers false to everything, which is what a non-member is.
  """
  @spec can?(Scope.t() | nil, capability()) :: boolean()
  # A project token holds `:use` on its own project when its API access is write, and nothing
  # else anywhere: not `:manage`, and not any other project. Four conditions, and the mutation
  # that drops any is caught by `project_token_test.exs` ("Access for a token scope").
  def can?(%Scope{token: %Forge.Git.Token{} = token, project: project}, capability)
      when not is_nil(project),
      do:
        capability == :use and token.api_access == :write and token.job_id == nil and
          token.project_id == project.id

  def can?(%Scope{role: role}, capability) when not is_nil(role),
    do: capability in capabilities(role)

  def can?(_scope, _capability), do: false

  @doc "The capabilities a role carries. The only place a role name is read."
  @spec capabilities(Member.role()) :: [capability()]
  def capabilities(:admin), do: [:use, :manage]
  def capabilities(:member), do: [:use]

  @doc """
  `:ok` when the scope may do this, `{:error, :forbidden}` otherwise.

  The shape `Forge.Operator` wants, so that a guard is one `with` clause rather than an `if`
  around a function body.
  """
  @spec ensure(Scope.t() | nil, capability()) :: :ok | {:error, :forbidden}
  def ensure(scope, capability) do
    if can?(scope, capability), do: :ok, else: {:error, :forbidden}
  end
end
