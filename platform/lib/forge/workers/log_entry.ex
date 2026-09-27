defmodule Forge.Workers.LogEntry do
  @moduledoc """
  One line of a machine's log (`docs/design/worker-log.md`): something the platform saw happen to
  the machine, or something the machine reported of itself — never what a job's agent did.
  Written by `Forge.Workers.Log`, which bounds every field; there is no changeset, because nothing
  a person types ever becomes one.
  """

  use Ecto.Schema

  @foreign_key_type :binary_id
  schema "worker_log" do
    belongs_to :worker, Forge.Workers.Worker
    field :at, :utc_datetime_usec
    field :source, Ecto.Enum, values: [:platform, :worker]
    field :type, :string
    field :level, Ecto.Enum, values: [:info, :warning, :error]
    field :message, :string
    field :job_id, :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
