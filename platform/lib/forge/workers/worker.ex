defmodule Forge.Workers.Worker do
  @moduledoc """
  A machine that hosts jobs. Empty until the worker tier; the local worker manager registers
  as one row so jobs always have a `worker_id`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workers" do
    field :provider, :string
    field :provider_id, :string
    field :status, Ecto.Enum, values: [:creating, :ready, :busy, :idle, :destroyed]
    field :token_hash, :string, redact: true
    field :memory_budget, :integer
    field :last_seen_at, :utc_datetime

    has_many :jobs, Forge.Jobs.Job

    timestamps(type: :utc_datetime)
  end

  def changeset(worker, attrs) do
    worker
    |> cast(attrs, [:provider, :provider_id, :status, :token_hash, :memory_budget, :last_seen_at])
    |> validate_required([:provider, :status])
  end
end
