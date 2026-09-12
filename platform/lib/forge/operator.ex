defmodule Forge.Operator do
  @moduledoc """
  The human operations, each existing once and reachable from the API, the pages and the
  Mix tasks. Every function takes the acting user, returns `{:ok, ticket}` or
  `{:error, reason}`, and notifies subscribers of the ticket on success.
  """

  alias Forge.Accounts.User
  alias Forge.Artifacts
  alias Forge.Engine
  alias Forge.Events
  alias Forge.Jobs
  alias Forge.Tickets
  alias Forge.Tickets.Ticket

  @doc "Answers the open question `key`; resumes the waiting job once it has no open blocking questions."
  @spec answer(Ticket.t(), User.t(), String.t(), map()) :: {:ok, Ticket.t()} | {:error, term()}
  def answer(%Ticket{} = ticket, %User{} = user, key, attrs) do
    with %{} = question <-
           Artifacts.find_open_question(ticket.id, key) || {:error, {:no_open_question, key}},
         {:ok, _answer} <- Artifacts.answer(question, user.id, attrs) do
      resume_if_unblocked(ticket, question)
      notify(ticket)
    end
  end

  defp resume_if_unblocked(ticket, question) do
    job_id = question.artifact_version.author["id"]

    with %{status: :waiting} = job <- Jobs.get!(job_id),
         [] <- Artifacts.open_blocking_questions(ticket.id, job.id) do
      Jobs.resume(job)
    else
      _ -> :ok
    end
  end

  @doc "Decides the pending transition."
  @spec decide(Ticket.t(), User.t(), :approved | :rejected, String.t() | nil) ::
          {:ok, Ticket.t()} | {:error, term()}
  def decide(%Ticket{} = ticket, %User{} = user, decision, comment)
      when decision in [:approved, :rejected] do
    with {:ok, ticket} <- Engine.decide(ticket, user.id, decision, comment) do
      notify(ticket)
    end
  end

  @doc "Takes a declared transition by hand. Options: `:outcome`, `:comment`."
  @spec transition(Ticket.t(), User.t(), String.t(), keyword()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def transition(%Ticket{} = ticket, %User{} = user, to, opts \\ []) do
    with {:ok, ticket} <- Engine.choose(ticket, user.id, to, opts) do
      notify(ticket)
    end
  end

  @doc "Writes a new version of a document, authored by the user."
  @spec edit(Ticket.t(), User.t(), String.t(), String.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def edit(%Ticket{} = ticket, %User{} = user, name, content) do
    with {:ok, _version} <-
           Artifacts.record_version(ticket.id, name, :document, {:user, user.id}, %{
             content: content
           }) do
      notify(ticket)
    end
  end

  defp notify(%Ticket{id: id}) do
    ticket = Tickets.get!(id)
    Events.notify(ticket.id)
    {:ok, ticket}
  end
end
