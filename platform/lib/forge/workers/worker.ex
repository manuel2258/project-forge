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
    # What the machine said about its harness at `ready`, verbatim. Read only to show and to
    # offer; nothing is scheduled on it. See docs/design/worker-channel.md § What a worker offers.
    field :harness, :map
    field :last_seen_at, :utc_datetime
    field :idle_since, :utc_datetime
    # Whether the platform may destroy this machine. False for one the operator provisioned;
    # see docs/design/worker-tier.md § Managed and unmanaged.
    field :managed, :boolean, default: true

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
      :harness,
      :last_seen_at,
      :idle_since,
      :managed
    ])
    |> validate_required([:provider, :status])
  end
end
