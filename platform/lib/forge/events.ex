defmodule Forge.Events do
  @moduledoc """
  The append-only event log. Every mutation in the platform writes an event in the same
  transaction; contexts build an `Ecto.Multi` and call `log/4` on it.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Events.Event
  alias Forge.Repo

  @type actor :: :system | {:user, String.t()} | {:job, String.t()}

  @doc """
  Adds an event insert to `multi` under `name`. `attrs` may hold `:ticket_id`, `:job_id`
  and `:payload`; `payload` may also be a function of the multi's changes so far, for
  events that reference rows inserted earlier in the same transaction.
  """
  @spec log(Multi.t(), atom(), String.t(), actor(), map() | (map() -> map())) :: Multi.t()
  def log(%Multi{} = multi, name, type, actor, attrs \\ %{}) do
    Multi.insert(multi, name, fn changes ->
      attrs = if is_function(attrs, 1), do: attrs.(changes), else: attrs
      Event.changeset(%Event{}, Map.merge(attrs, %{type: type, actor: encode_actor(actor)}))
    end)
  end

  @doc "Inserts one event outside any other transaction."
  @spec append(String.t(), actor(), map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def append(type, actor, attrs \\ %{}) do
    %Event{}
    |> Event.changeset(Map.merge(attrs, %{type: type, actor: encode_actor(actor)}))
    |> Repo.insert()
  end

  @spec for_ticket(String.t()) :: [Event.t()]
  def for_ticket(ticket_id) do
    Repo.all(from e in Event, where: e.ticket_id == ^ticket_id, order_by: e.seq)
  end

  @spec for_job(String.t()) :: [Event.t()]
  def for_job(job_id) do
    Repo.all(from e in Event, where: e.job_id == ^job_id, order_by: e.seq)
  end

  @spec encode_actor(actor()) :: map()
  def encode_actor(:system), do: %{"kind" => "system", "id" => nil}
  def encode_actor({:user, id}), do: %{"kind" => "user", "id" => id}
  def encode_actor({:job, id}), do: %{"kind" => "job", "id" => id}
end
