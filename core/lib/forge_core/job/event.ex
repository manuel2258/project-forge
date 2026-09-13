defmodule ForgeCore.Job.Event do
  @moduledoc """
  A normalised harness event on its way from the worker to the platform: a `type` without the
  `job.harness.` prefix, and a payload. Harness drivers produce these (`ForgeWorker.Harness`),
  the channel carries them, and the platform writes them to the event log.

  The only thing this module exists for is the crossing. A map that went through JSON comes
  back with string keys and has to look like the one that did not.
  """

  @type t :: %{type: String.t(), payload: map()}

  @doc "The wire form: string keys, JSON-encodable."
  @spec to_map(t()) :: map()
  def to_map(%{type: type, payload: payload}), do: %{"type" => type, "payload" => payload}

  @doc """
  An event from the wire. An event with no type is not an event: the platform logs by type,
  so one without a type has nowhere to go.
  """
  @spec from_map(map()) :: {:ok, t()} | :error
  def from_map(map) when is_map(map) do
    type = Map.get(map, "type", Map.get(map, :type))
    payload = Map.get(map, "payload", Map.get(map, :payload)) || %{}

    if is_binary(type) and type != "" and is_map(payload) do
      {:ok, %{type: type, payload: payload}}
    else
      :error
    end
  end

  def from_map(_other), do: :error
end
