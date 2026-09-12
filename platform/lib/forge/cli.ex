defmodule Forge.CLI do
  @moduledoc """
  Shared pieces of the `mix forge.*` tasks: booting without the scheduler, resolving
  `project#number` references and users, and printing.
  """

  alias Forge.{Accounts, Events, Jobs, Projects, Tickets}
  alias Forge.Tickets.Ticket

  @doc "Starts the application with the job scheduler off; tasks only write rows."
  def boot do
    Mix.Task.run("app.config")
    config = Application.get_env(:forge, Forge.Jobs, [])
    Application.put_env(:forge, Forge.Jobs, Keyword.put(config, :run_jobs, false))
    Mix.Task.run("app.start")
  end

  @doc "Resolves `name#number`, or a bare number when exactly one project exists."
  @spec ticket(String.t()) :: Ticket.t()
  def ticket(ref) do
    {project_name, number} =
      case String.split(ref, "#", parts: 2) do
        [name, number] -> {name, number}
        [number] -> {only(Projects.list(), "project", "use project#number").name, number}
      end

    case Tickets.fetch(project_name, number) do
      {:ok, ticket, _project} -> ticket
      :error -> fail("no ticket #{ref}")
    end
  end

  @doc "The user for `--user EMAIL`, or the only user when there is exactly one."
  def user(opts) do
    case Keyword.get(opts, :user) do
      nil -> only(Forge.Repo.all(Accounts.User), "user", "pass --user EMAIL")
      email -> Accounts.get_user_by_email(email) || fail("unknown user #{email}")
    end
  end

  defp only([one], _what, _hint), do: one
  defp only([], what, hint), do: fail("no #{what} registered; #{hint}")
  defp only(_many, what, hint), do: fail("more than one #{what}; #{hint}")

  @doc "Label for a ticket: `project#number`."
  def label(%Ticket{} = ticket), do: "#{Tickets.project_of(ticket).name}##{ticket.number}"

  @doc "A one-screen view of a ticket: state, jobs, artifacts and the event timeline."
  def show(%Ticket{} = ticket) do
    lines = [
      "#{label(ticket)}  #{ticket.title}",
      "state: #{ticket.state}  status: #{ticket.status}  cost: $#{ticket.cost_usd}  branch: #{ticket.branch}",
      pending_line(ticket),
      "",
      "jobs:"
    ]

    jobs =
      Enum.map(Jobs.for_ticket(ticket.id), fn job ->
        "  #{job.state} ##{job.attempt}  #{job.status}  #{job.outcome || "-"}#{if job.declared_outcome, do: " (#{job.declared_outcome})", else: ""}  turns=#{job.turns} cost=$#{job.cost_usd}"
      end)

    artifacts =
      Enum.map(Forge.Artifacts.list(ticket.id), fn artifact ->
        latest = Forge.Artifacts.latest(ticket.id, artifact.name)
        "  #{artifact.name}  v#{latest.version}  #{artifact.kind}"
      end)

    events =
      Enum.map(Events.for_ticket(ticket.id), fn event ->
        "  #{event.seq}  #{Calendar.strftime(event.inserted_at, "%H:%M:%S")}  #{event.type}  #{Events.summary(event)}"
      end)

    Enum.join(lines ++ jobs ++ ["", "artifacts:"] ++ artifacts ++ ["", "events:"] ++ events, "\n")
  end

  defp pending_line(%Ticket{pending_transition: nil}), do: "pending: none"

  defp pending_line(%Ticket{pending_transition: p}),
    do: "pending: #{p["from"]} -> #{p["to"]} needs approval of #{Enum.join(p["approve"], ", ")}"

  @doc "Prints the queue."
  def queue do
    case Forge.Queue.items() do
      [] -> "queue is empty"
      items -> Enum.map_join(items, "\n", &queue_line/1)
    end
  end

  defp queue_line(%{kind: :question, ticket: ticket, question: q}) do
    options =
      if q.options == [],
        do: "",
        else: " options: #{Enum.join(q.options, " | ")} (default #{q.default})"

    "QUESTION  #{label(ticket)}  [#{q.key}] #{q.text}#{options}"
  end

  defp queue_line(%{kind: :approval, ticket: ticket, detail: d}) do
    "APPROVAL  #{label(ticket)}  #{d["from"]} -> #{d["to"]}: approve #{Enum.join(d["approve"], ", ")}"
  end

  defp queue_line(%{kind: :stuck, ticket: ticket, detail: d}) do
    "STUCK     #{label(ticket)}  in #{d.state}; choose a transition with forge.transition"
  end

  defp queue_line(%{kind: :review, ticket: ticket, detail: d}) do
    "REVIEW    #{label(ticket)}  in #{d.state}; next: #{Enum.join(d.transitions, ", ")}"
  end

  def fail(message) do
    Mix.raise(message)
  end
end
