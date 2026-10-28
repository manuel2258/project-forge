defmodule Forge.ReleaseTickets do
  @moduledoc """
  A project's native release: the workflow that sets `release: true`, started by a project admin
  with an optional note, titled until its version is known, and concluded by its own workflow
  (`docs/design/ticket-types.md` § Releases).

  Named for what it holds rather than `Forge.Release`, which is the release tasks.

  Nothing here concludes a release. The engine already takes an edge with no `approve` by itself
  and merges on entering an `on_enter: merge` state, so a release whose last edge asks for nobody
  ends on its own, and one that asks for a person waits for them: the workflow decides.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.{Events, Repo, Tickets, TicketTypes}
  alias Forge.Jobs.Job
  alias Forge.Projects.Project
  alias Forge.Tickets.Ticket
  alias ForgeCore.Document

  @title "Release in progress"

  # A semantic version, optionally `v`-prefixed. It becomes a title, so it is held to a shape a
  # title can safely be rather than to whatever a document says.
  @version ~r/\Av?\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?\z/
  @version_max_bytes 64

  @doc "The title a release has until its version is known."
  @spec placeholder_title() :: String.t()
  def placeholder_title, do: @title

  @doc """
  `Forge.Tickets.types/2`'s answer without the release types, which the ticket form and the
  proposal select never offer. A project whose only types are releases has none left, and says so
  as admission does.
  """
  @spec ordinary({:ok, map()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  def ordinary({:ok, %{types: types} = result}) do
    # `[] when types != []` is defensive: a listing with no types at all is not a project of only
    # releases, and would be refused as one. `Tickets.types/2` never gives one with its default
    # `single: true`; the unit test calls this with one to hold the line.
    case Enum.reject(types, & &1.release) do
      [] when types != [] -> {:error, {:only_release_types, Enum.map(types, & &1.path)}}
      remaining -> {:ok, %{result | types: remaining}}
    end
  end

  def ordinary({:error, _reason} = error), do: error

  @doc """
  What the project page says of the release: `{:ok, entry}` for the one workflow that sets the
  flag, whose `workflow` may be an error so that it is shown broken, or `{:error,
  :no_release_workflow}` or `{:error, {:several_release_workflows, paths}}`. The rule is
  `TicketTypes.for_release/2`'s, applied to the same listing.
  """
  @spec status({:ok, map()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  def status({:ok, %{form: form, types: types}}) do
    layout = %{form: form, types: types, not_types: []}

    case TicketTypes.for_release(layout, for(type <- types, type.release, do: type.name)) do
      {:ok, name, _path} -> {:ok, Enum.find(types, &(&1.name == name))}
      {:error, reason} -> {:error, reason}
    end
  end

  def status({:error, _reason}), do: {:error, :no_release_workflow}

  @doc """
  Whether `ticket` pinned `release: true`. **The one model of "is this ticket a release"**: `open/1`
  asks the same thing of the same jsonb in SQL, and re-pinning, restoring and renaming ask it here,
  so that none of them reads the pin a second way. A pin with no key, or any value but `true`, is
  not one.
  """
  @spec release?(Ticket.t()) :: boolean()
  def release?(%Ticket{workflow: workflow}), do: workflow["release"] == true

  @doc """
  The project's open release, or nil: a ticket in an active or stuck status whose pinned workflow
  carries `release: true`. A pin with no such key is not a release, which is every ticket
  admitted before the flag existed.
  """
  @spec open(Project.t()) :: Ticket.t() | nil
  def open(%Project{id: id}) do
    Repo.one(
      from t in Ticket,
        where:
          t.project_id == ^id and t.status in ^Ticket.open_statuses() and
            fragment("? -> 'release' = 'true'::jsonb", t.workflow),
        order_by: [asc: t.number],
        limit: 1
    )
  end

  @doc """
  Starts the project's release: a ticket of the release workflow, titled `placeholder_title/0`,
  whose body is `note` trimmed. `{:error, {:release_open, ticket}}` when one is already open,
  and the reasons `Forge.Tickets.prepare_release/1` has when the project has none.

  **The check and the admission share the project row's lock**, the one `Tickets.put_admit/5`
  takes for the number, so two starts serialise and the second sees the first: a double tap makes
  one ticket.

  The caller has checked who may (`Forge.Operator.start_release/3`).
  """
  @spec start(Project.t(), String.t() | nil, Events.actor()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def start(%Project{} = project, note, actor) do
    note = String.trim(note || "")

    with :ok <- check_note(note),
         {:ok, prepared} <- Tickets.prepare_release(project) do
      Multi.new()
      |> Multi.run(:release_lock, fn repo, _changes -> lock_and_check(repo, project.id) end)
      |> Tickets.put_admit(prepared, project, %{title: @title, body: note}, actor)
      |> Repo.transaction()
      |> case do
        {:ok, %{ticket: ticket}} ->
          Events.notify(ticket.id)
          {:ok, ticket}

        {:error, :release_lock, reason, _changes} ->
          {:error, reason}

        {:error, step, reason, _changes} ->
          {:error, {step, reason}}
      end
    end
  end

  # The lock is what makes two concurrent starts one ticket, and no test reaches it: the sandbox
  # gives every process a test starts the one connection, so two starts cannot interleave there
  # (`ReleaseTicketsTest`, "while one is open"). Taking the lock after the check, or not at all,
  # is a mutation nothing here can see.
  defp lock_and_check(repo, project_id) do
    repo.one!(from p in Project, where: p.id == ^project_id, lock: "FOR UPDATE")

    case open(%Project{id: project_id}) do
      nil -> {:ok, nil}
      ticket -> {:error, {:release_open, ticket}}
    end
  end

  @doc """
  Adds to `multi` the check that restoring `ticket` does not make a second release open: a
  cancelled release is not open, so `start/3` allows another beside it, and bringing the first
  back would otherwise leave two. Adds nothing for a ticket that is not a release. Takes the same
  lock `start/3` does, and answers `{:release_open, ticket}` through the step `:release_lock`.
  """
  @spec put_restorable(Multi.t(), Ticket.t()) :: Multi.t()
  def put_restorable(multi, %Ticket{} = ticket) do
    if release?(ticket),
      do:
        Multi.run(multi, :release_lock, fn repo, _ -> lock_and_check(repo, ticket.project_id) end),
      else: multi
  end

  defp check_note(note) do
    case Document.text_error(note) do
      nil -> :ok
      why -> {:error, {:invalid_note, why}}
    end
  end

  @doc """
  Adds the rename a job's documents ask for to `multi`: on a release ticket, the first document
  (by name) whose front matter carries a `version` that is a semantic version becomes the title,
  and `ticket.renamed` records it.

  **It never returns an error and adds nothing it cannot do**, so it cannot fail the job that
  caused it: an ordinary ticket, a version of another shape or length, a number where a string
  was meant (`version: 0.17` is a float), and a version equal to the title all add nothing.
  """
  @spec put_rename(Multi.t(), Ticket.t(), Job.t(), %{String.t() => Document.t()}) :: Multi.t()
  def put_rename(multi, %Ticket{} = ticket, %Job{} = job, documents) do
    with true <- release?(ticket),
         {name, version} when version != ticket.title <- version(documents) do
      multi
      |> Multi.update(:renamed, Ticket.rename_changeset(ticket, %{title: version}))
      |> Events.log(:renamed_event, "ticket.renamed", {:job, job.id}, %{
        ticket_id: ticket.id,
        job_id: job.id,
        payload: %{"from" => ticket.title, "to" => version, "document" => name}
      })
    else
      _not_a_rename -> multi
    end
  end

  # Sorted so that "the first document by name" is said by the code and not left to map order.
  # Dropping the sort is an equivalent mutant: a map of up to 32 keys iterates in key order
  # already, and this is unobservable under 33 documents (`ForgeCore.Job.Correction` makes the same note).
  defp version(documents) do
    documents
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find_value(fn {name, %Document{front_matter: front_matter}} ->
      version = Map.get(front_matter, "version")
      if semantic?(version), do: {name, version}
    end)
  end

  # A string: `version: 0.17` is a float to YAML and `version: 1` an integer, neither a version.
  defp semantic?(version) when is_binary(version),
    do: byte_size(version) <= @version_max_bytes and Regex.match?(@version, version)

  defp semantic?(_other), do: false
end
