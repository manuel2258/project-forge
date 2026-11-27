defmodule ForgeWeb.Api.TicketController do
  use ForgeWeb, :controller

  alias Forge.{Artifacts, Events, Jobs, Operator, Projects, Proposals, Queue, Repo, Tickets}
  alias ForgeWeb.Api.Render

  action_fallback ForgeWeb.Api.FallbackController

  # Both run before `:load_ticket`: a refusal that waited for the lookup would be a 404 for a
  # ticket that is not there and a 403 for one that is.
  plug ForgeWeb.Plugs.ApiAccess,
       :writable
       when action in [
              :create,
              :edit,
              :answer,
              :approve,
              :transition,
              :retry,
              :extend,
              :cancel,
              :restore,
              :hold,
              :release,
              :stop,
              :take_over,
              :hand_back,
              :keep_work,
              :clear_warm_build,
              :title,
              :milestone,
              :move,
              :accept_proposal,
              :decline_proposal
            ]

  # A person's: a file a token attached is an admin's to withdraw, and a token is neither
  # (`docs/design/attachments.md` § Withdrawing).
  plug ForgeWeb.Plugs.ApiAccess, :person_only when action in [:queue, :withdraw]

  plug :load_ticket
       when action not in [
              :index,
              :create,
              :queue,
              :me,
              :proposals,
              :accept_proposal,
              :decline_proposal
            ]

  # After the two above and the lookup: the body of a request that was refused is never read.
  plug ForgeWeb.Plugs.ApiFiles
       when action in [
              :create,
              :edit,
              :answer,
              :approve,
              :transition,
              :retry,
              :extend,
              :accept_proposal
            ]

  def me(%{assigns: %{current_scope: %{token: %{} = token, project: project}}} = conn, _params) do
    json(conn, %{
      token: %{
        id: token.id,
        name: token.name,
        project: project.name,
        git: token.git_access,
        api: token.api_access,
        expires_at: token.expires_at
      }
    })
  end

  def me(conn, _params) do
    user = conn.assigns.current_scope.user
    json(conn, %{id: user.id, email: user.email, node_admin: user.node_admin})
  end

  defp project_name(ticket), do: Projects.get!(ticket.project_id).name

  def queue(conn, _params) do
    items =
      conn.assigns.current_scope.user
      |> Queue.items()
      |> Enum.map(&Render.queue_item(&1, &1.project.name))

    json(conn, %{items: items})
  end

  # `?state=` is one state name and `?open=true` is status active or stuck; both are optional and
  # they combine. Any other `open` value is no filter, as an unknown query parameter is.
  def index(conn, %{"project" => name} = params) do
    with %{} = project <- find_project(conn, name) do
      json(conn, %{tickets: listed(project, params)})
    end
  end

  def index(conn, params) do
    tickets = conn |> scoped_projects() |> Enum.flat_map(&listed(&1, params))
    json(conn, %{tickets: tickets})
  end

  # A state is a name: anything else (`?state[]=x`, a NUL, bytes that are not UTF-8) names no
  # state, so it lists nothing rather than everything or a 500 from the database.
  defp listed(project, params) do
    case filters(params) do
      :none -> []
      filters -> project |> Tickets.list(filters) |> render_all(project)
    end
  end

  # One read of what every row needs, not one per row — but for a ticket on hold, whose `stoppable`
  # and `waiting_on_release` are a query each (`Forge.Engine.stoppable?/1`,
  # `waiting_on_release_or_job/1`): a list's held rows cost that, and the rest cost nothing.
  defp render_all(tickets, project) do
    started = MapSet.new(Tickets.started_ids(Enum.map(tickets, & &1.id)))
    names = Forge.Milestones.names(project.id)

    Enum.map(tickets, fn ticket ->
      Render.ticket(ticket, project.name, started: ticket.id in started, milestones: names)
    end)
  end

  defp filters(params) do
    open = if params["open"] == "true", do: [open: true], else: []

    case params["state"] do
      nil ->
        open

      state when is_binary(state) ->
        if valid_text?(state), do: [state: state] ++ open, else: :none

      _not_a_name ->
        :none
    end
  end

  # Postgres refuses a NUL, or bytes that are not UTF-8, in a text parameter. The `String.valid?`
  # half cannot be reached from a query string (Plug answers 400 for invalid UTF-8 there first),
  # only from a path segment, which the raw route's test does reach: an equivalent mutant for
  # `state`, live for `name`.
  defp valid_text?(text), do: String.valid?(text) and not String.contains?(text, <<0>>)

  # **`Operator.admit/3` is the guard, and the only one.** This used to find the project among
  # the caller's own and then call `Tickets.admit/3` — a second check with its own idea of who
  # may admit (any membership row, where `Operator` asks `:use`), and an admission the Operator
  # never saw. The project is resolved by name alone here so that nothing but `admit/3` decides,
  # and its refusal is the same 404 as a project that does not exist: not a member and does not
  # exist are the same answer (`docs/design/identity.md` § Projects and members). It runs before
  # the ticket is validated, so a malformed request into somebody else's project is not a 422
  # that says the project is there. `docs/design/api-and-ui.md` § Operations.
  def create(conn, %{"project" => name} = params) do
    attrs = %{
      attachments: conn.assigns[:attachments],
      title: params["title"] || "",
      body: params["body"] || "",
      ticket_type: params["ticket_type"],
      on_hold: on_hold(params),
      outside_work: outside_work(params),
      start_commit: params["start_commit"],
      via: :api,
      milestone_id: params["milestone_id"]
    }

    with %{} = project <- Projects.by_name(name) || {:error, :not_found},
         {:ok, ticket} <- admit(project, actor(conn), attrs) do
      conn |> put_status(:created) |> json(Render.ticket(ticket, project.name))
    end
  end

  # Start or hold is the caller's to say (`docs/design/ui.md` § Creating things): a boolean, or the
  # strings a form sends. Anything else is nothing said, which the operation refuses.
  defp on_hold(%{"on_hold" => value}) when value in [true, "true"], do: true
  defp on_hold(%{"on_hold" => value}) when value in [false, "false"], do: false
  defp on_hold(_params), do: nil

  # Outside work is opened in place of a start or a hold (`docs/design/outside-work.md`): `true`
  # asks for it, and anything else is not asking.
  defp outside_work(%{"outside_work" => value}) when value in [true, "true"], do: true
  defp outside_work(_params), do: nil

  defp admit(project, actor, attrs) do
    case Operator.admit(project, actor, attrs) do
      {:error, :forbidden} -> {:error, :not_found}
      other -> other
    end
  end

  def show(conn, _params) do
    %{ticket: ticket, project: project} = conn.assigns

    json(conn, %{
      ticket: Render.ticket(ticket, project.name, offers: true),
      jobs: Enum.map(Jobs.for_ticket(ticket.id), &Render.job/1),
      # The commands the ticket ran, with the warm build each reported (`Render.command/1`).
      commands: Render.commands(Jobs.commands_for_ticket(ticket.id)),
      artifacts:
        Enum.map(
          Artifacts.list(ticket.id),
          &Render.artifact(&1, Artifacts.latest(ticket.id, &1.name))
        ),
      open_questions: Enum.map(Artifacts.open_questions(ticket.id), &Render.question/1)
    })
  end

  @doc """
  The ticket's timeline, oldest first. `limit` (a whole number from 1 to 1000) and `before` (an
  event's `seq`) page it: the newest `limit` events below `before`. A value that is not one is
  refused naming the parameter — never clamped, never ignored — and `before` only bounds the
  ticket's own events, whoever's `seq` it is (`docs/design/api-and-ui.md`).
  """
  def events(conn, params) do
    with {:ok, paging} <- paging(params) do
      json(conn, %{
        events: Enum.map(Events.for_ticket(conn.assigns.ticket.id, paging), &Render.event/1)
      })
    end
  end

  @bigint 9_223_372_036_854_775_807

  defp paging(params) do
    with {:ok, limit} <-
           whole(params["limit"], 1, 1000, "limit is a whole number from 1 to 1000"),
         {:ok, before} <-
           whole(params["before"], 1, @bigint, "before is the seq of an event, a whole number") do
      {:ok, Enum.reject([limit: limit, before: before], &is_nil(elem(&1, 1)))}
    end
  end

  # Absent is no bound; present is a whole number in range, parsed whole (`Integer.parse/1` leaving
  # nothing behind), or refused.
  defp whole(nil, _min, _max, _detail), do: {:ok, nil}

  # Digits only: `Integer.parse/1` alone would take `+5`. With the pattern in front, `{n, ""}` below
  # cannot fail to match a digit string, so loosening it to `{n, _}` is an equivalent mutant: no test
  # is written for it.
  defp whole(value, min, max, detail) when is_binary(value) do
    with true <- String.match?(value, ~r/\A[0-9]+\z/),
         {n, ""} when n >= min and n <= max <- Integer.parse(value) do
      {:ok, n}
    else
      _other -> {:error, {:bad_request, detail}}
    end
  end

  defp whole(_value, _min, _max, detail), do: {:error, {:bad_request, detail}}

  @doc """
  The merge decision as data: the diff, the documents the change was built from, the presentations
  an agent wrote about it, the questions answered and the total cost. The same material the review
  page draws, because the API is the product surface and the page is one client of it.
  """
  def review(conn, _params) do
    %{ticket: ticket, project: project} = conn.assigns

    case Artifacts.latest(ticket.id, ForgeCore.Workflow.changeset_artifact()) do
      nil -> {:error, :not_found}
      changeset -> json(conn, Render.review(ticket, project, changeset))
    end
  end

  def job(conn, %{"job_id" => job_id} = params) do
    ticket = conn.assigns.ticket

    with {:ok, paging} <- paging(params) do
      case Enum.find(
             Jobs.for_ticket(ticket.id) ++ Jobs.commands_for_ticket(ticket.id),
             &(&1.id == job_id)
           ) do
        nil ->
          {:error, :not_found}

        job ->
          json(conn, %{
            job: Render.job_with_spec(job),
            events: Enum.map(Events.for_job(job.id, paging), &Render.event/1)
          })
      end
    end
  end

  @doc """
  A command's log as text, exactly as the command wrote it, and with `?times=true` each line behind
  the milliseconds since the command started and a tab (empty where the line's time was not kept).
  Live lines while the command runs, the stored log and its times after. It is text and not JSON
  because a log need not be UTF-8 (`docs/design/worker-tier.md` § Looking into a copy).
  """
  def log(conn, %{"job_id" => job_id} = params) do
    case Enum.find(Jobs.commands_for_ticket(conn.assigns.ticket.id), &(&1.id == job_id)) do
      nil -> {:error, :not_found}
      job -> send_log(conn, job, params["times"] == "true")
    end
  end

  defp send_log(conn, %{status: :running} = job, timed?) do
    lines = Jobs.command_log(job, tail: Forge.Jobs.Lines.max_lines()).lines
    body = Enum.map(lines, fn {ms, text} -> [if(timed?, do: timed(ms)), text, ?\n] end)
    send_text(conn, body)
  end

  defp send_log(conn, job, timed?) do
    case Forge.Jobs.CommandLog.raw(job) do
      {:ok, bytes, _times} when not timed? ->
        send_text(conn, bytes)

      {:ok, bytes, times} ->
        lines = Forge.Jobs.CommandLog.lines(bytes)
        times = List.to_tuple(times || [])

        body =
          lines
          |> Enum.with_index()
          |> Enum.map(fn {line, index} -> [timed(time_at(times, index)), line, ?\n] end)

        send_text(conn, body)

      :none ->
        {:error, :not_found}

      {:error, :too_large} ->
        {:error,
         {:bad_request, "the log is too large to be read here; download it as its artifact"}}
    end
  end

  defp time_at(times, index) when index < tuple_size(times), do: elem(times, index)
  defp time_at(_times, _index), do: nil

  defp timed(nil), do: "\t"
  defp timed(ms), do: [Integer.to_string(ms), ?\t]

  # Bytes, as the log has them: no charset is claimed.
  defp send_text(conn, body) do
    conn
    |> put_resp_content_type("text/plain", nil)
    |> send_resp(200, body)
  end

  def artifact(conn, %{"name" => name} = params) do
    ticket = conn.assigns.ticket

    with {:ok, version} <- requested_version(ticket.id, name, params["version"]) do
      json(conn, Render.version(version, name))
    end
  end

  @doc """
  Every artifact of the ticket with every version of it, so a client chooses what to fetch. One
  call, no limit: a ticket with hundreds of versions answers with all of them.
  """
  def artifacts(conn, _params) do
    listing =
      for {artifact, versions} <- Artifacts.versions_for_ticket(conn.assigns.ticket.id),
          do: Render.artifact_listing(artifact, versions)

    json(conn, %{artifacts: listing})
  end

  @doc """
  The stored bytes of one version (`ForgeWeb.ArtifactBytes`). The `content_hash` the listing gives
  is `sha256:` of exactly these bytes, but for a blob recorded without a hash (`uri:…`). A changeset is a commit and not a file: 422 saying where
  the diff is. A version that is not a positive integer, or is not there, is a 404 like any
  other thing that is not yours.
  """
  def raw(conn, %{"name" => name, "version" => requested}) do
    ticket = conn.assigns.ticket

    # Postgres refuses a NUL, or bytes that are not UTF-8, in a text parameter, and that would be
    # a 500 for a name no artifact can have.
    # `n > 0` is an equivalent mutant: versions start at 1, so a zero or a negative finds nothing
    # below either way. It is kept so the address says what a version number is.
    with true <- valid_text?(name),
         {n, ""} when n > 0 <- Integer.parse(requested),
         %{} = version <- Enum.find(Artifacts.versions(ticket.id, name), &(&1.version == n)),
         nil <- Artifacts.commit(version),
         %Plug.Conn{} = sent <- ForgeWeb.ArtifactBytes.send_version(conn, name, version) do
      sent
    else
      sha when is_binary(sha) -> {:error, :not_a_file}
      _absent -> {:error, :not_found}
    end
  end

  defp requested_version(ticket_id, name, nil) do
    case Artifacts.latest(ticket_id, name) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  defp requested_version(ticket_id, name, requested) do
    case Integer.parse(requested) do
      {n, ""} when n > 0 ->
        case Enum.find(Artifacts.versions(ticket_id, name), &(&1.version == n)) do
          nil -> {:error, :not_found}
          version -> {:ok, version}
        end

      _ ->
        {:error, {:bad_request, "version must be a positive integer"}}
    end
  end

  def edit(conn, %{"name" => name, "content" => content}) do
    with {:ok, ticket} <-
           Operator.edit(conn.assigns.ticket, actor(conn), name, content, nil, files(conn)) do
      json(conn, Render.version(Artifacts.latest(ticket.id, name), name))
    end
  end

  def answer(conn, %{"key" => key} = params) do
    attrs = %{choice: params["choice"], text: params["text"]}

    with {:ok, ticket} <-
           Operator.answer(conn.assigns.ticket, actor(conn), key, attrs, files(conn)) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  def approve(conn, params) do
    decision = if params["decision"] == "rejected", do: :rejected, else: :approved

    with {:ok, ticket} <-
           Operator.decide(
             conn.assigns.ticket,
             actor(conn),
             decision,
             params["comment"],
             nil,
             files(conn)
           ) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  def transition(conn, %{"to" => to} = params) do
    opts = [outcome: params["outcome"], comment: params["comment"]] ++ files(conn)

    with {:ok, ticket} <- Operator.transition(conn.assigns.ticket, actor(conn), to, opts) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  # Runs the state the ticket rests in again (`Forge.Engine.retry/3`), with the person's note and
  # the raise of the ticket's cap they ask for. The queue serves `retry` on a stuck item, and a
  # client that can read it can act on it.
  def retry(conn, params) do
    opts = [note: params["note"], raise: params["raise"]] ++ files(conn)

    with {:ok, ticket} <- Operator.retry(conn.assigns.ticket, actor(conn), opts) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name, offers: true))
    end
  end

  # Reopens the job that ran out of budget (`Forge.Engine.extend/5`): `tokens`, `turns`, `timeout`, `note`
  # and `raise`. The queue and the ticket serve `extend` — the offer — and a client that can read
  # it can act on it.
  def extend(conn, %{"job_id" => job_id} = params) do
    attrs = Map.take(params, ~w(tokens turns timeout note raise))

    with {:ok, ticket} <-
           Operator.extend(conn.assigns.ticket, actor(conn), job_id, attrs, files(conn)) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name, offers: true))
    end
  end

  # The files that came with the request, for the operation to claim in its own transaction: whole
  # or not at all (`ForgeWeb.Plugs.ApiFiles`). None for a JSON request.
  defp files(conn), do: [attachments: conn.assigns[:attachments]]

  @doc """
  Withdraws a file of the ticket: every version of `:file`, or the one `:version` names, with an
  optional `reason` (`docs/design/attachments.md` § Withdrawing). A person's only; the rule — the
  attacher or an admin of the project — is `Forge.Attachments.withdraw/5`'s.
  """
  def withdraw(conn, %{"file" => file} = params) do
    %{ticket: ticket, current_scope: %{user: user}} = conn.assigns

    with {:ok, which} <- withdrawn_version(params["version"]),
         true <- valid_text?(file) || {:error, :not_found},
         {:ok, rows} <-
           Forge.Attachments.withdraw(
             {:ticket, ticket.id},
             user,
             Forge.Attachments.artifact_name(file),
             which,
             reason(params)
           ) do
      json(conn, %{
        withdrawn: Enum.map(rows, &Render.withdrawn/1),
        file: file
      })
    end
  end

  defp withdrawn_version(nil), do: {:ok, :all}

  defp withdrawn_version(version) do
    case Integer.parse(version) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> {:error, {:bad_request, "version must be a positive integer"}}
    end
  end

  defp reason(%{"reason" => reason}) when is_binary(reason), do: reason
  defp reason(_params), do: nil

  def cancel(conn, _params) do
    with {:ok, ticket} <- Operator.cancel(conn.assigns.ticket, actor(conn)) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  def restore(conn, _params) do
    with {:ok, ticket} <- Operator.restore(conn.assigns.ticket, actor(conn)) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  # The hold (`docs/design/workflow-grammar-v1.md` § Holding a ticket). Each is `Operator`'s, so a
  # token and a person are guarded by the one function the page calls.
  def hold(conn, _params), do: respond(conn, Operator.hold(conn.assigns.ticket, actor(conn)))

  def release(conn, _params),
    do: respond(conn, Operator.release(conn.assigns.ticket, actor(conn), via: :api))

  # Taking a ticket over and handing it back (`docs/design/outside-work.md`). `Operator`'s guard
  # and `via: :api`, so the event says which door it came through.
  def take_over(conn, params) do
    respond(
      conn,
      Operator.take_over(conn.assigns.ticket, actor(conn),
        running: params["running"],
        via: :api
      )
    )
  end

  def hand_back(conn, params) do
    opts = [note: params["note"], via: :api] ++ if(params["to"], do: [to: params["to"]], else: [])

    respond(conn, Operator.hand_back(conn.assigns.ticket, actor(conn), opts))
  end

  # Keeps the work a job's moved-branch stop set aside (`docs/design/outside-work.md` § Keeping the
  # job's work). `job_id` names the stop the press is about, so a second press is refused.
  def keep_work(conn, %{"job_id" => job_id}) when is_binary(job_id),
    do: respond(conn, Operator.keep_work(conn.assigns.ticket, actor(conn), job_id, via: :api))

  def keep_work(_conn, _params), do: {:error, {:bad_request, "job_id is the id of the job"}}

  def stop(conn, _params), do: respond(conn, Operator.stop_now(conn.assigns.ticket, actor(conn)))

  # Makes the ticket's warm build unusable on every machine (`docs/design/worker-tier.md` § The
  # command copy). `Operator`'s guard, so a person and a project token that may write are one rule;
  # a job's own token never reaches it (`ApiAuth`).
  def clear_warm_build(conn, _params) do
    with {:ok, ticket} <- Operator.clear_warm_build(conn.assigns.ticket, actor(conn)) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name, offers: true))
    end
  end

  def title(conn, %{"title" => title}) when is_binary(title),
    do: respond(conn, Operator.retitle(conn.assigns.ticket, actor(conn), title))

  def title(_conn, _params), do: {:error, {:bad_request, "title is text"}}

  # `milestone_id` null takes the ticket out of its milestone.
  def milestone(conn, %{"milestone_id" => id}) when is_binary(id) or is_nil(id),
    do: respond(conn, Operator.set_milestone(conn.assigns.ticket, actor(conn), id))

  def milestone(_conn, _params), do: {:error, {:bad_request, "milestone_id is an id or null"}}

  # `to` is `top`, `up`, `down` or `bottom`; `before` is the number of a ticket in the same order.
  def move(conn, params) do
    with {:ok, to} <- move_target(params, conn.assigns.project) do
      respond(conn, Operator.move_ticket(conn.assigns.ticket, actor(conn), to))
    end
  end

  defp move_target(%{"to" => to}, _project) when to in ~w(top up down bottom),
    do: {:ok, String.to_existing_atom(to)}

  defp move_target(%{"before" => number}, project) when is_integer(number) or is_binary(number) do
    with {n, ""} <- Integer.parse(to_string(number)),
         %{id: id} <- Repo.get_by(Forge.Tickets.Ticket, project_id: project.id, number: n) do
      {:ok, {:before, id}}
    else
      _none -> {:error, :not_in_order}
    end
  end

  defp move_target(_params, _project),
    do: {:error, {:bad_request, "to is top, up, down or bottom, or before is a ticket number"}}

  defp respond(conn, {:ok, ticket}),
    do: json(conn, Render.ticket(ticket, conn.assigns.project.name))

  defp respond(_conn, {:error, _reason} = error), do: error

  # Open proposals are per project, not per ticket: a project chat's proposal has no ticket, and
  # the operator's question is "what has been suggested here", not "what did ticket 12 suggest".
  def proposals(conn, %{"project" => name}) do
    with %{} = project <- find_project(conn, name) do
      json(conn, %{proposals: Enum.map(Proposals.open(project.id), &Render.proposal/1)})
    end
  end

  def accept_proposal(conn, %{"version_id" => version_id} = params) do
    with {:ok, ticket} <-
           Operator.accept_proposal(
             version_id,
             actor(conn),
             params["comment"],
             params["ticket_type"],
             [on_hold: on_hold(params), milestone_id: params["milestone_id"]] ++ files(conn)
           ) do
      json(conn, Render.ticket(ticket, project_name(ticket)))
    end
  end

  def decline_proposal(conn, %{"version_id" => version_id} = params) do
    with {:ok, decision} <- Operator.decline_proposal(version_id, actor(conn), params["comment"]) do
      json(conn, %{version_id: decision.artifact_version_id, decision: "declined"})
    end
  end

  defp load_ticket(%{params: %{"project" => name, "number" => number}} = conn, _opts) do
    # A ticket in a project the caller is not a member of answers 404, not 403. Not a member and
    # does not exist are the same answer — `docs/design/identity.md` § Projects and members.
    case Tickets.fetch(name, number) do
      {:ok, ticket, project} ->
        if member?(conn, project),
          do: conn |> assign(:project, project) |> assign(:ticket, ticket),
          else: missing(conn, name, number)

      :error ->
        missing(conn, name, number)
    end
  end

  defp missing(conn, name, number) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{reason: "not_found", detail: "no ticket #{name}##{number}"}})
    |> halt()
  end

  # A project token is a member of exactly the project it was issued for. The comparison is on the
  # id, not the name: the scope carries the project row the token names.
  defp member?(%{assigns: %{current_scope: %{token: %{} = token}}}, project),
    do: token.project_id == project.id

  defp member?(conn, project),
    do: Projects.member?(project, conn.assigns.current_scope.user)

  # The caller's own projects, never the node's. Every list below goes through one of these.
  defp scoped_projects(%{assigns: %{current_scope: %{token: %{} = token, project: project}}}),
    do: Enum.filter([project], &(&1.id == token.project_id))

  defp scoped_projects(conn), do: Projects.list(conn.assigns.current_scope.user)

  defp find_project(conn, name) do
    case Enum.find(scoped_projects(conn), &(&1.name == name)) do
      nil -> {:error, :not_found}
      project -> project
    end
  end

  defp actor(%{assigns: %{current_scope: %{token: %{} = token}}}), do: token
  defp actor(conn), do: conn.assigns.current_scope.user
end
