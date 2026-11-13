defmodule ForgeWeb.Access do
  @moduledoc """
  Resolving the current scope against the project a page or endpoint is about.

  A non-member does not get a refusal, they get a miss: not a member and does not exist are the
  same answer, because telling someone that a project exists but is not theirs tells them it
  exists. `docs/design/identity.md` § Projects and members.

  This is the read side. The write side is `Forge.Operator`, which refuses on its own and does
  not trust any page to have called this first.
  """

  alias Forge.Accounts.Scope
  alias Forge.Projects.Project

  @doc """
  The scope resolved for `project`, raising `Ecto.NoResultsError` when the user is not a member.

  Raising is what the surrounding code already does for a project that is genuinely absent, so
  the two cases render the same page, which is the point.
  """
  @spec project_scope!(Scope.t(), Project.t()) :: Scope.t()
  def project_scope!(%Scope{} = scope, %Project{} = project) do
    if member?(scope, project),
      do: Scope.for_project(scope, project),
      else: raise(Ecto.NoResultsError, queryable: Project)
  end

  @doc """
  Whether `project` is the user's to see: the one test `project_scope!/2` raises on, for a page
  that must answer a miss without raising — the not-found page (`ForgeWeb.NotFound`).
  """
  @spec member?(Scope.t(), Project.t()) :: boolean()
  def member?(%Scope{} = scope, %Project{} = project),
    do: Forge.Access.can?(Scope.for_project(scope, project), :use)

  @doc "The project by name, raising the same way when it is absent or not the user's."
  @spec project_by_name!(Scope.t(), String.t()) :: {Project.t(), Scope.t()}
  def project_by_name!(%Scope{} = scope, name) do
    case Forge.Projects.by_name(name) do
      nil -> raise Ecto.NoResultsError, queryable: Project
      project -> {project, project_scope!(scope, project)}
    end
  end
end
