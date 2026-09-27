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

  alias Ecto.Multi
  alias Forge.Accounts.User
  alias Forge.{Events, Projects}
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
  Edits one of `user`'s templates, named by an id that came off the wire.

  **This changes nothing about machines that already exist**, by construction rather than by
  care: a worker was given copies of these values at creation and does not read through to the
  row (`docs/design/provisioning.md` § Two tables).

  **The owner is checked here, and kept.** The row is read scoped to `user`, so somebody else's
  template is `:not_found` exactly as a missing one is; and `user_id` is set by this function, as
  `create_template/2` sets it, so no attribute in `attrs` can hand the template — and the
  credential it spends — to another account. It used to take the row and no actor, and the
  templates page's own scoped read was the only thing deciding whose row it was
  (`docs/design/identity.md` § Where the guard lives).
  """
  @spec update_template(User.t(), term(), map()) ::
          {:ok, Template.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_template(%User{id: user_id} = user, id, attrs) do
    with {:ok, template} <- owned(user, id) do
      template |> Template.changeset(put_user(attrs, user_id)) |> Repo.update()
    end
  end

  @doc """
  The provider credential a machine made from `template` would be billed to, checked again.

  `Template.changeset/2` refuses a credential that is not the template owner's, but a changeset
  guards only the rows written after it: a template saved before it checked anything still names
  whatever credential it was given, and every machine made from it is billed there. So the
  question is asked again where it costs money, of the row the driver is about to be handed,
  with the changeset's own `Template.credential_mismatch/3`
  (`docs/design/provisioning.md` § Whose account).

  `{:ok, nil}` for a template with no credential, which is a local one. `{:error, message}`, in
  the words the template's failure counter records, for one its owner may not spend.
  """
  @spec spendable_credential(Template.t()) :: {:ok, Credential.t() | nil} | {:error, String.t()}
  def spendable_credential(%Template{provider_credential_id: nil}), do: {:ok, nil}

  def spendable_credential(%Template{provider_credential_id: id} = template) do
    case Repo.get(Credential, id) do
      # Deleted since the template was read — the column is nilified — so this is the template
      # with no credential that the clause above answers, and the driver says what that means.
      nil -> {:ok, nil}
      credential -> spendable(template, credential)
    end
  end

  defp spendable(template, credential) do
    case Template.credential_mismatch(template.user_id, template.provider, credential) do
      nil ->
        {:ok, credential}

      :not_owner ->
        {:error, "its provider credential belongs to another user"}

      {:wrong_provider, theirs} ->
        {:error, "its provider credential is for #{theirs}, not #{template.provider}"}
    end
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
      Multi.new()
      |> Multi.insert(
        :assignment,
        ProjectTemplate.changeset(%ProjectTemplate{}, %{
          project_id: project_id,
          template_id: template.id
        })
      )
      |> Events.log(:event, "template.assigned", {:user, user.id}, %{
        project_id: project_id,
        payload: %{"template_id" => template.id, "project_id" => project_id}
      })
      |> Repo.transaction()
      |> case do
        # A ticket stuck because nothing could make its job a machine may have been waiting for
        # exactly this (`Forge.Engine.resume_placement/2`).
        {:ok, %{assignment: assignment}} ->
          Forge.Engine.resume_placement(project_id, {:user, user.id})
          {:ok, assignment}

        {:error, :assignment, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc "Stops `project` having machines made from `template`. The same two rules apply."
  @spec unassign(User.t(), String.t(), String.t()) :: :ok | {:error, :not_found | :not_a_member}
  def unassign(%User{} = user, template_id, project_id) do
    with {:ok, template} <- owned(user, template_id),
         :ok <- member?(user, project_id) do
      Multi.new()
      |> Multi.delete_all(
        :assignment,
        from(a in ProjectTemplate,
          where: a.template_id == ^template.id and a.project_id == ^project_id
        )
      )
      |> Events.log(:event, "template.unassigned", {:user, user.id}, %{
        project_id: project_id,
        payload: %{"template_id" => template.id, "project_id" => project_id}
      })
      |> Repo.transaction()

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
  Records that the image a machine was made from speaks `protocol`, learnt from the machine being
  refused at join (`docs/design/provisioning.md` § A snapshot that speaks the wrong protocol).

  **Only if the template still names that image.** A template edited onto another snapshot while
  the refused machine was booting is not the one that was refused, and teaching it would stop it
  making machines from an image nobody has tried. Null matches null: a template naming no image
  boots the driver's default, and a machine made from it was made from that.
  """
  #
  # The build comes with it when the machine said one: a machine's first join runs the release its
  # image was made with, so it is as good as a label. One that said none leaves the build alone.
  @spec learn_protocol(String.t(), String.t() | nil, non_neg_integer(), String.t() | nil) :: :ok
  def learn_protocol(template_id, image, protocol, build \\ nil) do
    query =
      case image do
        nil -> from(t in Template, where: t.id == ^template_id and is_nil(t.image))
        image -> from(t in Template, where: t.id == ^template_id and t.image == ^image)
      end

    learnt = [image_protocol: protocol] ++ if(build, do: [image_build: build], else: [])

    {_count, _} =
      Repo.update_all(query, set: learnt ++ [updated_at: DateTime.utc_now(:second)])

    :ok
  end

  @doc """
  Why no machine may be made from this template's image, or nil when one may: its known protocol
  is one this platform does not accept. Nil for an image whose protocol is unknown — unlabelled
  and never heard from — which is probed rather than refused (`Forge.Workers`).

  One sentence, because two surfaces say it: the template's failure when a job asks for a machine,
  and the templates page before any does.
  """
  @spec image_refusal(Template.t()) :: String.t() | nil
  def image_refusal(%Template{image_protocol: nil}), do: nil

  def image_refusal(%Template{image_protocol: protocol}) do
    unless ForgeCore.WorkerProtocol.compatible?(protocol) do
      "its image speaks worker protocol #{protocol}, and this platform accepts " <>
        ForgeCore.WorkerProtocol.range()
    end
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
