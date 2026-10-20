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

  # What `holds?/2` reads of a template, and so what an edit has to change for `for_demand/2` or
  # `could_ever_hold?/2` to answer differently. The image beside its protocol, because choosing
  # another image is how what is known of it changes (`Template.changeset/2`).
  #
  # `image_protocol` is in the list for a template naming a snapshot, which is the only kind the
  # gate reads it for: `speaks?/2` ignores it for a template on the mark, so a resolution writing
  # it cannot change what the gate answers and has nothing to bring back
  # (`docs/design/provisioning.md` § Editing a template).
  @holds [:memory, :cores, :accepts, :image, :image_protocol]

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

  **An edit to what the template could hold brings back the tickets stuck for want of it**, in
  every project it is assigned to — `@holds` above says which fields that is, and
  `docs/design/provisioning.md` § Editing a template why the rest are not.
  """
  @spec update_template(User.t(), term(), map()) ::
          {:ok, Template.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_template(%User{id: user_id} = user, id, attrs) do
    with {:ok, template} <- owned(user, id),
         changeset = Template.changeset(template, put_user(attrs, user_id)),
         {:ok, template} <- Repo.update(changeset) do
      if Enum.any?(@holds, &Map.has_key?(changeset.changes, &1)),
        do: resume_projects(template, {:user, user_id})

      {:ok, template}
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

  **A template on the mark that does not fit on what it stores comes last, and only when nothing
  fits.** Its stored protocol is its *last* resolution's, so whether it can serve a job needing a
  newer one is unknown until a create attempt re-resolves it — and both guesses were wrong. Read
  as *no*, the mark was never followed past a protocol bump, which is the case it exists for; read
  as *yes* and taken in order, a template on the mark was handed jobs ahead of a concrete template
  in the same project that would have served them, because order is by size and the protocol
  filter was what used to remove it. Preferring what is known keeps the second from happening and
  the fallback keeps the first from happening; `Forge.Workers` asks the job's protocol again of
  what it actually resolved (`docs/design/provisioning.md` § Where a machine comes from).
  """
  @spec for_demand(String.t(), map()) :: Template.t() | nil
  def for_demand(project_id, demand) do
    usable = usable(project_id)

    Enum.find(usable, &holds?(&1, demand)) || Enum.find(usable, &might_hold?(&1, demand))
  end

  @doc """
  Whether *any* template assigned to this project could ever hold `demand`.

  The distinction `docs/design/provisioning.md` § The gate insists on: a job that does not fit
  right now waits, and a job that could never fit sticks its ticket with the reason. Without
  this the second looks like the first for ever.
  """
  #
  # **`or might_hold?/2` is an equivalent mutant at the only caller, and is kept for the next one.**
  # `Forge.Workers.no_template_for/2` asks this only once `for_demand/2` has returned nil for the
  # same demand and the same `usable/1` set, which means neither predicate held for any template —
  # so dropping it changes no answer production can reach, and no test can honestly claim it does.
  # It is here because the two functions are the same question asked two ways, and a caller that
  # asks this one first would otherwise get *could never fit* for a template `for_demand/2` would
  # hand out.
  @spec could_ever_hold?(String.t(), map()) :: boolean()
  def could_ever_hold?(project_id, demand) do
    project_id |> usable() |> Enum.any?(&(holds?(&1, demand) or might_hold?(&1, demand)))
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
    accepts?(template, demand.kind) and speaks?(template, demand[:protocol]) and
      sized?(template, demand)
  end

  # Every dimension but the protocol, for a template on the mark: the one dimension whose stored
  # answer is about a snapshot it may no longer be on, and the one the create attempt re-asks of
  # what it resolved. `for_demand/2` says why this is a fallback and not the rule.
  defp might_hold?(%Template{} = template, demand) do
    Template.latest?(template) and accepts?(template, demand.kind) and sized?(template, demand)
  end

  defp sized?(%Template{} = template, demand),
    do: template.memory >= demand.memory and template.cores >= demand.cores

  @doc """
  Whether what is known of this template's image is new enough for a job needing `protocol`.

  **Asked of the same template at two moments, so one definition.** The gate asks it of what the
  row stores (`for_demand/2`); `Forge.Workers` asks it again of what a create attempt has just
  resolved, because for a template on the mark the row's answer was about the snapshot before.
  Two copies would be two places for *new enough* to disagree, and a template let through one and
  refused by the other would be a machine billed for nothing or a job stuck for no reason.

  Nil is unlabelled — unknown, not compatible — and is let through to be probed by one machine,
  whose join says what the snapshot speaks (`docs/design/provisioning.md` § A snapshot that
  speaks the wrong protocol).
  """
  @spec speaks?(Template.t(), non_neg_integer() | nil) :: boolean()
  # A labelled image older than the job needs makes a machine that joins and cannot take it — and
  # then another, every pass, up to `max_workers`. An unlabelled one is asked once: its first
  # machine's join says what it speaks (`Workers` holds the rest back while that one probes).
  def speaks?(_template, need) when need in [nil, 0], do: true
  def speaks?(%Template{image_protocol: nil}, _need), do: true
  def speaks?(%Template{image_protocol: protocol}, need), do: protocol >= need

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
  Records that a machine made from `image` reached `ready` for the first time: the recipe works.

  Consecutive, not cumulative — a template that has made a hundred good machines is not
  disabled by three bad ones spread across a year.

  **Only if the template still names that image**, as `learn_protocol/4` asks: a machine made from
  the snapshot before the one that took the template out of service says nothing about the one it
  names now. And only a first `ready` — the caller's to know — because a reconnect says nothing at
  all (`docs/design/provisioning.md` § A template that cannot make a working machine is taken out
  of service).

  **True when this put the template back in service**, which is an arrival as `enable/2` is: the
  caller brings back the tickets in its projects once the `ready` is written (`resume_projects/2`).
  Only then: a counter going from two to zero changes nothing the gate reads. Asked by the
  statement that does it, so two machines reporting at once cannot both say so.
  """
  @spec succeeded(String.t() | nil, String.t() | nil) :: boolean()
  def succeeded(nil, _image), do: false

  def succeeded(template_id, image) do
    reset = [failures: 0, last_error: nil, updated_at: DateTime.utc_now(:second)]
    naming = naming(template_id, image)

    {back, _} =
      Repo.update_all(from(t in naming, where: t.failures >= ^failure_limit()), set: reset)

    {_count, _} = Repo.update_all(from(t in naming, where: t.failures > 0), set: reset)
    back == 1
  end

  # The template, while it still resolves to the image a machine was made from. Null matches
  # null: a template naming no image boots the driver's default, and a machine made from it was
  # made from that.
  #
  # **`resolved_image` and not `image`**, because a template naming `latest` never holds a
  # concrete id in `image` while `workers.image` always does — so the comparison could never hold
  # for one, and both this and `learn_protocol/4` would have gone silently dead for it: a counter
  # that never resets and a protocol never learnt
  # (`docs/design/provisioning.md` § Where a machine comes from).
  defp naming(template_id, nil),
    do: from(t in Template, where: t.id == ^template_id and is_nil(t.resolved_image))

  defp naming(template_id, image),
    do: from(t in Template, where: t.id == ^template_id and t.resolved_image == ^image)

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
    learnt = [image_protocol: protocol] ++ if(build, do: [image_build: build], else: [])

    {_count, _} =
      Repo.update_all(naming(template_id, image),
        set: learnt ++ [updated_at: DateTime.utc_now(:second)]
      )

    :ok
  end

  @doc """
  The snapshot a template naming `latest` would be made from, out of a driver's listing, or nil
  when none carries the mark.

  **The newest of them when more than one does.** `bin/hetzner-image` marks the snapshot it built
  before it unmarks the one before — that order, so a build interrupted between the two leaves two
  marked rather than none, which would fail every create until somebody reran it — and the window
  is seconds. Either is a real worker image, but the newest is the one the operator just asked
  for. A listing with no `created` on its entries falls back to the driver's own order.
  """
  @spec current_image([Forge.Provider.image()]) :: Forge.Provider.image() | nil
  def current_image(images) do
    case Enum.filter(images, & &1[:current]) do
      [] -> nil
      marked -> Enum.max_by(marked, &(&1[:created] || ""))
    end
  end

  @doc """
  Points a template naming `latest` at `current`, the snapshot that carries the mark now.

  Called once per create attempt, before anything is asked of the driver, so that what reaches it
  and what is written onto the machine's row is the concrete snapshot and never the word
  (`docs/design/provisioning.md` § Where a machine comes from). Unlike `learn_protocol/4` there is
  no "only if the template still names that image" guard: the listing is authoritative about what
  `latest` means, and this *is* the template changing what it names.

  **What is known of the snapshot it lands on is `Template.learnt/4`'s to say**, which a save asks
  too: staying on the same snapshot keeps what was learnt about it, and moving to a different one
  takes that one's labels, nothing included.

  Returns the template as it now stands. Nothing is written when the three fields already say
  this, which is the common case: the mark moves when an image is built, not between two
  scheduling passes.
  """
  @spec resolve_latest(Template.t(), Forge.Provider.image()) :: Template.t()
  def resolve_latest(%Template{} = template, %{id: id} = current) do
    {build, protocol} =
      Template.learnt(
        template.resolved_image,
        id,
        {current[:build], current[:protocol]},
        {template.image_build, template.image_protocol}
      )

    resolved = %{resolved_image: id, image_build: build, image_protocol: protocol}
    asked = %{resolved_at: DateTime.utc_now(:second)}

    # **`resolved_at` is written on every resolution, the other three only when they changed.**
    # The timestamp is a record of a request that was made, which is what `asked_recently?/1`
    # rate-limits on, so it has to move even when the answer is the same; `updated_at` moves only
    # with the answer, so *nothing was written about this template* stays a thing a reader can
    # tell. The common case is still one small write and no change to what anything reads.
    if Map.take(template, Map.keys(resolved)) == resolved do
      write(template, asked)
    else
      write(template, Map.merge(resolved, asked), updated_at: DateTime.utc_now(:second))
    end
  end

  defp write(template, fields, also \\ []) do
    {_count, _} =
      Repo.update_all(
        from(t in Template, where: t.id == ^template.id),
        set: Map.to_list(fields) ++ also
      )

    struct!(template, fields)
  end

  @doc """
  Whether this template's mark was resolved too recently to ask the provider again.

  **What bounds the cost of a job nothing marked is new enough for.** Such a job waits rather than
  sticking its ticket (`Forge.Jobs.Scheduler`), so it is offered again every pass — and resolving
  on each one sent one listing request per pass per waiting job, 1800 an hour at the default two
  seconds against an account whose published limit is 3600. The 429 would come back through the
  template's own failure counter and disable it: the loop the probe was moved ahead of the
  catalogue call to avoid, reached by the one refusal that cannot be asked before resolving.

  **Only asked where the answer can only be a refusal.** `Forge.Workers` rate-limits a resolution
  whose stored answer already cannot serve the demand; one that is going to make a machine is
  never rate-limited, because what a machine is made from has to be current
  (`docs/design/provisioning.md` § Where a machine comes from).

  Null is *never asked* — every template naming a snapshot, and every row that predates the
  column — and is never recent.
  """
  @spec asked_recently?(Template.t()) :: boolean()
  def asked_recently?(%Template{resolved_at: nil}), do: false

  def asked_recently?(%Template{resolved_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :millisecond) < resolve_after_ms()
  end

  @doc """
  How long a template on the mark holds its last answer before asking the provider again, when
  asking could only repeat a refusal. A minute: short enough that a build is picked up while the
  operator is still looking at the page, long enough that a waiting job costs one request a minute
  rather than one every pass.
  """
  @spec resolve_after_ms() :: pos_integer()
  def resolve_after_ms,
    do: :forge |> Application.get_env(__MODULE__, []) |> Keyword.get(:resolve_after_ms, 60_000)

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

  **And it is an arrival, like assigning it.** A ticket stuck because every template assigned to
  its project was disabled holds a pending job the scheduler no longer offers, so the tickets stuck
  for placement in every project this template is assigned to are brought back — when it was
  disabled. Enabling one that was not changes nothing the gate reads, and a ticket brought back for
  nothing is stuck again on the next pass and pushed to its project's members once more.
  """
  @spec enable(User.t(), String.t()) :: {:ok, Template.t()} | {:error, term()}
  def enable(%User{} = user, id) do
    with {:ok, template} <- owned(user, id),
         {:ok, enabled} <-
           template |> Ecto.Changeset.change(failures: 0, last_error: nil) |> Repo.update() do
      if disabled?(template), do: resume_projects(enabled, {:user, user.id})
      {:ok, enabled}
    end
  end

  @doc """
  Brings back the tickets stuck for want of a machine in every project `template` is assigned to,
  now that it may make what it could not: enabled, edited in what it could hold, or back in
  service after a machine of its own reported (`docs/design/credentials.md` § How a job picks).

  Which tickets come back is `Forge.Engine.resume_placement/2`'s to decide. A wrong guess is stuck
  again by the next pass, and pushed again, so the callers ask first whether anything changed.
  """
  @spec resume_projects(Template.t(), Forge.Events.actor()) :: :ok
  def resume_projects(%Template{} = template, actor) do
    template |> for_projects() |> Enum.each(&Forge.Engine.resume_placement(&1.id, actor))
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
