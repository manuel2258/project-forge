defmodule Forge.Provisioning do
  @moduledoc """
  Worker templates, provider credentials, and which projects may have machines made for them.

  See `docs/design/provisioning.md`. Two rules live here rather than in a changeset, because
  both are about the *caller* and a changeset can be bypassed:

    * a template and a credential belong to the user who made them, and
    * only that user may assign a template to a project, and only to a project they are a
      member of — because creating from it spends their credential
      (`docs/design/identity.md` § Workers).
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Accounts.User
  alias Forge.Projects
  alias Forge.Provisioning.{Credential, ProjectTemplate, Template}
  alias Forge.Repo

  # -- credentials ----------------------------------------------------------------------------

  @doc "The provider credentials this user owns."
  @spec credentials(User.t()) :: [Credential.t()]
  def credentials(%User{id: user_id}) do
    Repo.all(from c in Credential, where: c.user_id == ^user_id, order_by: c.name)
  end

  @doc "A credential of this user's, or nil. Never another user's, whatever the id."
  @spec credential(User.t(), String.t()) :: Credential.t() | nil
  def credential(%User{id: user_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(from c in Credential, where: c.id == ^id and c.user_id == ^user_id)
      :error -> nil
    end
  end

  @doc """
  Records a provider credential for `user`.

  The secret is a map — `%{"token" => "..."}` for Hetzner — and is sealed before it is stored.
  """
  @spec create_credential(User.t(), map()) ::
          {:ok, Credential.t()} | {:error, Ecto.Changeset.t()}
  def create_credential(%User{id: user_id}, attrs) do
    attrs |> put_user(user_id) |> then(&Credential.changeset(%Credential{}, &1)) |> Repo.insert()
  end

  @doc """
  Removes a credential.

  Templates that named it keep working in the sense that their rows survive — the column is
  nilified — but they can no longer create anything, and the page says so. That is better than
  refusing the delete: a credential the operator wants gone is usually one that has leaked.
  """
  @spec delete_credential(User.t(), String.t()) :: :ok | {:error, :not_found}
  def delete_credential(%User{} = user, id) do
    case credential(user, id) do
      nil -> {:error, :not_found}
      credential -> with {:ok, _} <- Repo.delete(credential), do: :ok
    end
  end

  # -- templates ------------------------------------------------------------------------------

  @doc "The templates this user owns."
  @spec templates(User.t()) :: [Template.t()]
  def templates(%User{id: user_id}) do
    Repo.all(from t in Template, where: t.user_id == ^user_id, order_by: t.name)
  end

  @doc "A template of this user's, or nil."
  @spec template(User.t(), String.t()) :: Template.t() | nil
  def template(%User{id: user_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(from t in Template, where: t.id == ^id and t.user_id == ^user_id)
      :error -> nil
    end
  end

  @spec create_template(User.t(), map()) :: {:ok, Template.t()} | {:error, Ecto.Changeset.t()}
  def create_template(%User{id: user_id}, attrs) do
    attrs |> put_user(user_id) |> then(&Template.changeset(%Template{}, &1)) |> Repo.insert()
  end

  @doc """
  Edits a template.

  **This changes nothing about machines that already exist**, by construction rather than by
  care: a worker was given copies of these values at creation and does not read through to the
  row (`docs/design/provisioning.md` § Two tables).
  """
  @spec update_template(Template.t(), map()) ::
          {:ok, Template.t()} | {:error, Ecto.Changeset.t()}
  def update_template(%Template{} = template, attrs) do
    template |> Template.changeset(attrs) |> Repo.update()
  end

  @spec delete_template(User.t(), String.t()) :: :ok | {:error, :not_found}
  def delete_template(%User{} = user, id) do
    case template(user, id) do
      nil -> {:error, :not_found}
      template -> with {:ok, _} <- Repo.delete(template), do: :ok
    end
  end

  # -- assignment -----------------------------------------------------------------------------

  @doc """
  Lets `project` have machines made from `template`.

  Refused unless the caller owns the template *and* is a member of the project. The first is
  what stops an admin spending somebody else's money; the second is what stops a template owner
  pointing their own spending at a project they have nothing to do with.
  """
  @spec assign(User.t(), String.t(), String.t()) ::
          {:ok, ProjectTemplate.t()} | {:error, :not_found | :not_a_member | Ecto.Changeset.t()}
  def assign(%User{} = user, template_id, project_id) do
    with {:ok, template} <- owned(user, template_id),
         :ok <- member?(user, project_id) do
      %ProjectTemplate{}
      |> ProjectTemplate.changeset(%{project_id: project_id, template_id: template.id})
      |> Repo.insert()
    end
  end

  @doc "Stops `project` having machines made from `template`. The same two rules apply."
  @spec unassign(User.t(), String.t(), String.t()) :: :ok | {:error, :not_found | :not_a_member}
  def unassign(%User{} = user, template_id, project_id) do
    with {:ok, template} <- owned(user, template_id),
         :ok <- member?(user, project_id) do
      Repo.delete_all(
        from a in ProjectTemplate,
          where: a.template_id == ^template.id and a.project_id == ^project_id
      )

      :ok
    end
  end

  @doc "The projects this template may have machines made for, by name."
  @spec for_projects(Template.t()) :: [Forge.Projects.Project.t()]
  def for_projects(%Template{id: id}) do
    Repo.all(
      from p in Forge.Projects.Project,
        join: a in ProjectTemplate,
        on: a.project_id == p.id,
        where: a.template_id == ^id,
        order_by: p.name
    )
  end

  @doc """
  The templates a project may have machines made from, cheapest capacity first.

  Ordered by memory so that `for_demand/2` picking the first that fits picks the smallest that
  fits — a refine job should not create a build machine because one was assigned.
  """
  @spec for_project(String.t()) :: [Template.t()]
  def for_project(project_id) do
    Repo.all(
      from t in Template,
        join: a in ProjectTemplate,
        on: a.template_id == t.id,
        where: a.project_id == ^project_id,
        order_by: [asc: t.memory, asc: t.cores, asc: t.name]
    )
  end

  @doc """
  The smallest template assigned to this project that could hold `demand`, or nil.

  Smallest rather than first-assigned: creating a thirty-two core machine for a job that
  declared one is how a fleet gets expensive without anybody deciding that it should.
  """
  @spec for_demand(String.t(), map()) :: Template.t() | nil
  def for_demand(project_id, demand) do
    project_id |> usable() |> Enum.find(&holds?(&1, demand))
  end

  @doc """
  Whether *any* template assigned to this project could ever hold `demand`.

  The distinction `docs/design/provisioning.md` § The gate insists on: a job that does not fit
  right now waits, and a job that could never fit sticks its ticket with the reason. Without
  this the second looks like the first for ever.
  """
  @spec could_ever_hold?(String.t(), map()) :: boolean()
  def could_ever_hold?(project_id, demand) do
    project_id |> usable() |> Enum.any?(&holds?(&1, demand))
  end

  # **The gate skips a disabled template; the page does not.** The filter is here and not in
  # `for_project/1` because that is what the templates page lists, and a template you cannot
  # see is one you cannot enable again. It also used to be what decided between a template and
  # the node's own provider, so filtering there once meant *all disabled* silently became
  # *none assigned* and the platform made a local machine instead — the substitution the
  # fallback was removed for.
  defp usable(project_id), do: project_id |> for_project() |> Enum.reject(&disabled?/1)

  # A template with no `accepts` takes any kind, exactly as a worker with none does — the same
  # rule in the same words, because a template that said nothing and a machine that said
  # nothing must not mean different things.
  defp holds?(%Template{} = template, demand) do
    accepts?(template, demand.kind) and
      template.memory >= demand.memory and
      template.cores >= demand.cores
  end

  defp accepts?(%Template{accepts: nil}, _kind), do: true
  defp accepts?(%Template{accepts: []}, _kind), do: true
  defp accepts?(%Template{accepts: accepts}, kind), do: kind in accepts

  @doc """
  How many consecutive failures take a template out of service.

  Three: enough that one flake does not disable a working recipe, few enough that a loop is
  stopped in minutes rather than hours. Configurable because the right number depends on how
  flaky the provider is, not on anything this code knows.
  """
  @spec failure_limit() :: pos_integer()
  def failure_limit,
    do: :forge |> Application.get_env(__MODULE__, []) |> Keyword.get(:failure_limit, 3)

  @doc """
  Whether this template is out of service.

  **Derived, not stored.** A flag beside the counter is two facts about one thing, and the day
  they disagree there is no way to say which is true. Enabling is `enable/2`, which sets the
  counter back to zero.
  """
  @spec disabled?(Template.t()) :: boolean()
  def disabled?(%Template{failures: failures}), do: failures >= failure_limit()

  @doc """
  Records that this template failed to produce a working machine.

  Both kinds count and they are not the same failure: the driver refusing (no machine was
  made) and a machine that was made and never called home. The second is the one that matters —
  every create succeeded in the loop this was written for — and it is why the caller is
  `Forge.Workers` at two separate sites rather than one.
  """
  @spec failed(String.t() | nil, String.t()) :: :ok
  def failed(nil, _message), do: :ok

  def failed(template_id, message) do
    {_count, _} =
      Repo.update_all(
        from(t in Template, where: t.id == ^template_id),
        inc: [failures: 1],
        set: [last_error: String.slice(message, 0, 255), updated_at: DateTime.utc_now(:second)]
      )

    :ok
  end

  @doc """
  Records that a machine from this template reached `ready`: the recipe works.

  Consecutive, not cumulative — a template that has made a hundred good machines is not
  disabled by three bad ones spread across a year.
  """
  @spec succeeded(String.t() | nil) :: :ok
  def succeeded(nil), do: :ok

  def succeeded(template_id) do
    {_count, _} =
      Repo.update_all(
        from(t in Template, where: t.id == ^template_id and t.failures > 0),
        set: [failures: 0, last_error: nil, updated_at: DateTime.utc_now(:second)]
      )

    :ok
  end

  @doc """
  Puts a disabled template back into service, if it is the caller's.

  **Only a person does this.** Editing a template does not: a rename is not a fix, and a
  template that earns three more tries every time somebody touches it is the loop again with
  extra steps (`docs/design/provisioning.md` § A template that cannot make a working machine is
  taken out of service).
  """
  @spec enable(User.t(), String.t()) :: {:ok, Template.t()} | {:error, term()}
  def enable(%User{} = user, id) do
    with {:ok, template} <- owned(user, id) do
      template |> Ecto.Changeset.change(failures: 0, last_error: nil) |> Repo.update()
    end
  end

  @doc "How many machines exist from this template, against its own ceiling."
  @spec live_count(Template.t()) :: non_neg_integer()
  def live_count(%Template{id: id}) do
    Repo.one(
      from w in Forge.Workers.Worker,
        where: w.template_id == ^id and w.status != :destroyed,
        select: count(w.id)
    )
  end

  defp owned(%User{} = user, template_id) do
    case template(user, template_id) do
      nil -> {:error, :not_found}
      template -> {:ok, template}
    end
  end

  defp member?(%User{} = user, project_id) do
    case Projects.role(%Forge.Projects.Project{id: project_id}, user) do
      nil -> {:error, :not_a_member}
      _role -> :ok
    end
  end

  defp put_user(attrs, user_id) do
    attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("user_id", user_id)
  end
end
