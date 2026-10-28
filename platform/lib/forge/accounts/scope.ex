defmodule Forge.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Forge.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias Forge.Accounts.User
  alias Forge.Projects.Project

  defstruct user: nil, token: nil, project: nil, role: nil

  @type t :: %__MODULE__{
          user: User.t() | nil,
          token: Forge.Git.Token.t() | nil,
          project: Project.t() | nil,
          role: Forge.Projects.Member.role() | nil
        }

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Resolves the scope against a project, carrying the role the user holds there.

  `role` is nil for a non-member, and `Forge.Access` answers false to every capability for such
  a scope. Authorisation is therefore the same question as "did this resolve", which is what
  keeps a missing membership from reading as an unrestricted one.
  """
  @spec for_project(t(), Project.t()) :: t()
  def for_project(%__MODULE__{user: %User{} = user} = scope, %Project{} = project) do
    %{scope | project: project, role: Forge.Projects.role(project, user)}
  end

  @doc """
  The scope of a project token (`docs/design/identity.md` § Where the guard lives): no user, and
  the project it was issued for. Whether it may do anything there is `Forge.Access`'s to say.
  """
  @spec for_token(Forge.Git.Token.t(), Project.t()) :: t()
  def for_token(%Forge.Git.Token{} = token, %Project{} = project),
    do: %__MODULE__{token: token, project: project}
end
