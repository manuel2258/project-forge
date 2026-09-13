defmodule Forge.Workers.Worker do
  @moduledoc """
  A machine that hosts jobs: created on demand, destroyed after an idle period, and recorded
  from before it exists until after it is gone. See `docs/design/worker-tier.md`.
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
    field :idle_since, :utc_datetime

    has_many :jobs, Forge.Jobs.Job

    timestamps(type: :utc_datetime)
  end

  def changeset(worker, attrs) do
    worker
    |> cast(attrs, [
      :provider,
      :provider_id,
      :status,
      :token_hash,
      :memory_budget,
      :last_seen_at,
      :idle_since
    ])
    |> validate_required([:provider, :status])
  end
end
