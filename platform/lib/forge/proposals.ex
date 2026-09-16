defmodule Forge.Proposals do
  @moduledoc """
  Ticket proposals: an agent saying a ticket should exist, and a person deciding.

  The standard is `docs/design/ticket-proposals.md`. In one paragraph: any job may propose and
  no job may write, a proposal is one document artifact at one version scoped to the job that
  wrote it, and accepting it calls `Forge.Tickets.admit/3` — a proposal is a `ticket` document
  that has not been admitted yet.

  Nothing here creates a ticket on its own. `accept/3` takes the acting user because admission
  is the human act that widens the envelope, which is the only reason an agent is allowed to
  propose freely in the first place.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.{Artifacts, Events, Projects, Repo, Tickets}
  alias Forge.Artifacts.{Artifact, Version}
  alias Forge.Jobs.Job
  alias Forge.Proposals.Decision
  alias ForgeCore.{Proposal, Workflow}

  require Logger

  # The longest artifact name that is safe to store *and* to write as a filename.
  #
  # Two limits meet here and they count different things. `artifacts.name` is `varchar(255)`,
  # which counts characters; the backlog writes the same name as a file, and a filesystem
  # component is 255 *bytes*. A name within 255 bytes satisfies both, because a string of at
  # most 255 bytes is at most 255 characters — the reverse does not hold, which is the trap: a
  # 62-character multibyte name fits the column and then makes every later job on the project
  # fail at start with ENAMETOOLONG.
  @max_artifact_name_bytes 255

  @doc """
  How many proposals one job may have recorded.

  A cap held by the platform, beside the daily spend cap, rather than a key in
  `.forge/workflow.yml`: how many follow-ups an agent may raise is not the project's business
  to declare, for the same reason the state that discovers them cannot be known in advance.
  """
  @spec cap() :: pos_integer()
  def cap, do: Forge.Jobs.config(:max_proposals_per_job, 5)

  @doc """
  Adds the steps recording a finished run's proposals to `multi`.

  Called from the one place a job's result is written, so a proposal and the job that made it
  land in the same transaction. Proposals beyond `cap/0` are **refused loudly** — an event
  names each one — rather than dropped: the whole point of this path is that nothing an agent
  said goes missing in silence.

  Recording is **idempotent by content**, which is what makes it safe to call more than once for
  one job. A conversation collects its proposals every turn and `out/proposals/` accumulates, so
  turn five re-reports what turn one wrote; a workflow job resumed after a blocking question does
  the same. Writing those again as new versions would reopen a proposal the operator had already
  decided, because a decision attaches to a version and the newest one would have none.
  """
  @spec put_from_result(Multi.t(), Job.t(), map(), map()) :: Multi.t()
  def put_from_result(multi, %Job{} = job, proposals, invalid) do
    stored = stored_proposals(job.id)

    {named, unnameable} =
      proposals
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.split_with(fn {file, _proposal} -> storable_name?(file) end)

    invalid =
      Enum.into(unnameable, invalid, fn {file, _} ->
        {file, %{"reason" => too_long_reason(), "raw" => nil}}
      end)

    # An unreadable proposal is written too, as the text the agent wrote. § Malformed degrades,
    # never drops promises it is "kept verbatim as a version"; recording a filename and an error
    # message in an event is not keeping it, and left nothing for a person to look at. It stays
    # open and unacceptable — `accept/3` re-parses — so the operator sees what was written and
    # declines it, which is the whole point of not dropping it.
    texts =
      Enum.map(named, fn {file, %Proposal{} = proposal} ->
        {file, Proposal.to_document(proposal)}
      end) ++ keepable(invalid)

    fresh =
      Enum.reject(texts, fn {file, text} ->
        Map.get(stored, Workflow.proposal_artifact(file)) == text
      end)

    # The cap is on the job, not on the call: a conversation that could add five more every turn
    # would have no cap at all. What is already stored counts against it — but a *revision* of
    # something already stored is not a new proposal, so it is never what the cap refuses. At the
    # cap, an agent improving the wording of one proposal had the improvement refused for being
    # over a cap it was not over.
    {revised, added} =
      Enum.split_with(fresh, fn {file, _text} ->
        Map.has_key?(stored, Workflow.proposal_artifact(file))
      end)

    {new_kept, refused} = Enum.split(added, max(cap() - map_size(stored), 0))

    multi =
      Enum.reduce(revised ++ new_kept, multi, fn {file, text}, multi ->
        Artifacts.put_version(
          multi,
          {:proposal, file},
          {:job, job.id},
          Workflow.proposal_artifact(file),
          :document,
          {:job, job.id},
          # `parse: false` is load-bearing rather than an optimisation, and not for the reason
          # it first looks. Without it `put_version/7` runs `Document.parse/1`, which returns
          # `{:error, {:invalid_document, _}}` for text it cannot read — and this multi is the
          # one where a job's whole result is recorded. A proposal with a malformed `question`
          # block would therefore take the job's documents, cost, outcome and event down with
          # it, and the run would look as though it had never reported.
          #
          # It also stops `Question` rows being written against a finished job's artifact.
          # Those are dead rather than dangerous — `open_questions/1` is scoped by `ticket_id`
          # and a proposal is scoped to its job, so the queue never sees them — which is worth
          # saying because the opposite is the obvious guess.
          # See `docs/design/ticket-proposals.md` § Shape.
          %{content: text, parse: false}
        )
      end)

    multi
    |> log_refused(job, refused)
    |> log_invalid(job, invalid)
  end

  # Checked here rather than left to the database, because the database's answer is a raise
  # rather than an error: `put_from_result/4` runs inside the multi that records the job's whole
  # result, so a name the column refuses takes the job's documents, cost, outcome and event with
  # it — and takes them again on every retry, because the worker re-sends until it is acked.
  # Refusing the name is the same trade `parse: false` makes for the content.
  defp storable_name?(file) do
    byte_size(Workflow.proposal_artifact(file)) <= @max_artifact_name_bytes
  end

  defp too_long_reason do
    "file name too long: a proposal is stored under its own name, which must fit in " <>
      "#{@max_artifact_name_bytes} bytes once prefixed"
  end

  # The latest version of every proposal this job has already recorded, keyed by artifact name.
  defp stored_proposals(job_id) do
    latest =
      from v in Version,
        group_by: v.artifact_id,
        select: %{artifact_id: v.artifact_id, version: max(v.version)}

    Repo.all(
      from v in Version,
        join: a in Artifact,
        on: a.id == v.artifact_id,
        join: l in subquery(latest),
        on: l.artifact_id == v.artifact_id and l.version == v.version,
        where: a.job_id == ^job_id and like(a.name, ^(proposal_prefix() <> "%")),
        select: {a.name, v.content}
    )
    |> Map.new()
  end

  # The unreadable ones there is text to keep, under a name short enough to store. One with no
  # text — a symlink, a directory, a file that would not open — has nothing to keep, and its
  # reason in the event log is all there ever was.
  defp keepable(invalid) do
    for {file, %{"raw" => raw}} <- invalid,
        is_binary(raw),
        storable_name?(file),
        do: {file, raw}
  end

  defp log_refused(multi, _job, []), do: multi

  defp log_refused(multi, %Job{} = job, refused) do
    Events.log(multi, :proposals_refused, "proposal.refused", {:job, job.id}, %{
      ticket_id: job.ticket_id,
      job_id: job.id,
      payload: %{"files" => Enum.map(refused, &elem(&1, 0)), "cap" => cap()}
    })
  end

  defp log_invalid(multi, _job, invalid) when invalid == %{}, do: multi

  defp log_invalid(multi, %Job{} = job, invalid) do
    Events.log(multi, :proposals_invalid, "proposal.unreadable", {:job, job.id}, %{
      ticket_id: job.ticket_id,
      job_id: job.id,
      payload: %{"reasons" => Map.new(invalid, fn {file, why} -> {file, why["reason"]} end)}
    })
  end

  @doc """
  Every open proposal on a project, oldest first.

  Open means the latest version of the proposal's artifact has no decision. A decision on an
  earlier version does not close it — the operator rewrote the title and what they decided
  about is not what is there now, which is the rule `docs/design/data-model.md` already states
  for approvals.
  """
  @spec open(String.t()) :: [%{artifact: Artifact.t(), version: Version.t(), job: Job.t()}]
  def open(project_id) do
    Repo.all(
      from [v, a, j] in open_query(),
        where: j.project_id == ^project_id,
        select: %{artifact: a, version: v, job: j}
    )
  end

  @doc """
  How many proposals are open across every project.

  For the daily digest, which is where a proposal reaches a person who is not looking at a
  project page. Counted rather than listed because the digest says a number.
  """
  @spec open_count() :: non_neg_integer()
  def open_count, do: Repo.aggregate(from([v] in open_query(), select: v.id), :count)

  @doc "Open proposals made by the jobs of one ticket, which is where its page shows them."
  @spec open_for_ticket(String.t()) :: [%{artifact: Artifact.t(), version: Version.t()}]
  def open_for_ticket(ticket_id) do
    Repo.all(
      from [v, a, j] in open_query(),
        where: j.ticket_id == ^ticket_id,
        select: %{artifact: a, version: v}
    )
  end

  # Every proposal artifact's latest version that nothing has decided, with its artifact and the
  # job that wrote it. The latest version is found by joining a grouped subquery rather than by
  # ordering and limiting, because the caller wants one row per proposal and several proposals
  # at once.
  defp open_query do
    latest =
      from v in Version,
        group_by: v.artifact_id,
        select: %{artifact_id: v.artifact_id, version: max(v.version)}

    from v in Version,
      join: a in Artifact,
      on: a.id == v.artifact_id,
      join: j in Job,
      on: j.id == a.job_id,
      join: l in subquery(latest),
      on: l.artifact_id == v.artifact_id and l.version == v.version,
      left_join: d in Decision,
      on: d.artifact_version_id == v.id,
      where: like(a.name, ^(proposal_prefix() <> "%")) and is_nil(d.id),
      order_by: [asc: v.inserted_at, asc: a.name]
  end

  defp proposal_prefix, do: Workflow.proposal_artifact("")

  @doc "One proposal by the id of the version being decided, with everything a page needs."
  @spec get(String.t()) :: %{artifact: Artifact.t(), version: Version.t(), job: Job.t()} | nil
  def get(version_id) do
    Repo.one(
      from v in Version,
        join: a in Artifact,
        on: a.id == v.artifact_id,
        join: j in Job,
        on: j.id == a.job_id,
        where: v.id == ^version_id and like(a.name, ^(proposal_prefix() <> "%")),
        select: %{artifact: a, version: v, job: j}
    )
  end

  @doc "The decision on a version, or nil while it is still open."
  @spec decision(String.t()) :: Decision.t() | nil
  def decision(version_id),
    do: Repo.one(from d in Decision, where: d.artifact_version_id == ^version_id)

  @doc """
  Accepts a proposal: admits it as a ticket and records the decision, in one transaction.

  The admitted ticket pins the project's workflow **at accept time, not at propose time**, and
  the opposite reading is plausible enough to be worth stating. A proposal is not work in
  flight and holds nothing; it should run against whatever the project declares when a person
  says go, which may be long after an agent thought of it.
  """
  @spec accept(String.t(), String.t(), String.t()) ::
          {:ok, Forge.Tickets.Ticket.t()} | {:error, term()}
  def accept(version_id, user_id, comment \\ nil) do
    with {:ok, found} <- fetch_open(version_id),
         {:ok, proposal} <- parse(found.version) do
      admit(found, proposal, user_id, comment)
    end
  end

  # Admission and the decision in **one** transaction. They were two: `Tickets.admit/3`
  # committed and only then did the decision insert open its own, so any failure of the second
  # left a real ticket — numbered, branched, with a first job queued — that no decision pointed
  # at and no proposal came from, while the proposal stayed open to be accepted again. Two
  # concurrent accepts hit exactly that, every time.
  #
  # The unique index on `artifact_version_id` is now the guard rather than `fetch_open/1`'s
  # check-then-act: the loser's whole transaction rolls back, ticket included.
  #
  # One thing does not roll back, and it is worth knowing: `put_admit/5`'s `:branch` step calls
  # `Git.create_branch`, which is a filesystem effect. A rolled-back accept leaves the branch
  # without the ticket that named it. That is the pre-existing shape of `admit/3` and it is the
  # right way round — a stray ref is collectable, a stray ticket spends money.
  defp admit(found, proposal, user_id, comment) do
    project = Projects.get!(found.job.project_id)
    attrs = %{title: proposal.title, body: proposal.body}

    with {:ok, prepared} <- Tickets.prepare_admission(project) do
      Multi.new()
      |> Tickets.put_admit(prepared, project, attrs, {:user, user_id})
      |> put_decision(found, user_id, :accepted, comment)
      |> Repo.transaction()
      |> case do
        {:ok, %{ticket: ticket}} ->
          Events.notify(ticket.id)
          {:ok, ticket}

        {:error, :decision, %Ecto.Changeset{errors: errors}, _changes} ->
          decision_error(errors)

        {:error, step, reason, _changes} ->
          {:error, {step, reason}}
      end
    end
  end

  # The unique index on `artifact_version_id` is what makes two concurrent accepts safe, so the
  # constraint it raises has to come back as the same `:already_decided` that `fetch_open/1`
  # returns when it sees the decision first. Anything else from that insert is a real fault.
  defp decision_error(errors) do
    if Keyword.has_key?(errors, :artifact_version_id),
      do: {:error, :already_decided},
      else: {:error, {:decision, errors}}
  end

  @doc """
  Declines a proposal.

  Recorded rather than merely not accepted. Without the record the next job proposes the same
  thing, and the one after that — which is the failure the backlog an agent reads exists to
  prevent, and it cannot prevent it if a declined proposal leaves no trace.
  """
  @spec decline(String.t(), String.t(), String.t()) :: {:ok, Decision.t()} | {:error, term()}
  def decline(version_id, user_id, comment \\ nil) do
    with {:ok, found} <- fetch_open(version_id) do
      record_decision(found, user_id, :declined, comment)
    end
  end

  defp fetch_open(version_id) do
    case get(version_id) do
      nil -> {:error, :not_found}
      found -> if decision(version_id), do: {:error, :already_decided}, else: {:ok, found}
    end
  end

  # The stored text is what `Proposal.to_document/1` wrote, or what a person edited it into.
  # Either way it is parsed again here rather than trusted: an operator may have rewritten it
  # into something that no longer has a title, and admitting a ticket called "" is worse than
  # refusing.
  #
  # Tagged, not a bare list of errors: `ForgeWeb.Api.FallbackController` already answers a bare
  # list as `invalid_workflow`, which is a different thing that happens to have the same shape.
  defp parse(%Version{content: content}) when is_binary(content) do
    case Proposal.parse(content) do
      {:ok, proposal} -> {:ok, proposal}
      {:error, errors} -> {:error, {:invalid_proposal, errors}}
    end
  end

  defp parse(%Version{}), do: {:error, :no_content}

  # The decision and its event, as steps. `ticket` is read from the multi's own changes when
  # there is one, so an acceptance can name the ticket the same transaction is creating.
  defp put_decision(multi, found, user_id, decision, comment) do
    multi
    |> Multi.insert(:decision, fn changes ->
      ticket = changes[:ticket]

      Decision.changeset(%Decision{}, %{
        artifact_version_id: found.version.id,
        user_id: user_id,
        ticket_id: ticket && ticket.id,
        decision: decision,
        comment: comment
      })
    end)
    |> Events.log(:event, "proposal.#{decision}", {:user, user_id}, fn changes ->
      ticket = changes[:ticket]

      %{
        ticket_id: found.job.ticket_id,
        job_id: found.job.id,
        payload: %{
          "artifact" => found.artifact.name,
          "version_id" => found.version.id,
          "ticket_id" => ticket && ticket.id,
          "number" => ticket && ticket.number
        }
      }
    end)
  end

  defp record_decision(found, user_id, decision, comment) do
    Multi.new()
    |> put_decision(found, user_id, decision, comment)
    |> Repo.transaction()
    |> case do
      {:ok, %{decision: row}} -> {:ok, row}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end
