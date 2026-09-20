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
    # The other two dimensions of the gate (`docs/design/provisioning.md` § The gate). `cores`
    # is counted like `memory_budget`; `accepts` lists the job kinds this machine will take,
    # which is what keeps inference off a machine bought for builds.
    field :cores, :integer
    field :accepts, {:array, Ecto.Enum}, values: Forge.Jobs.Job.kinds()
    # What the machine said about its harness at `ready`, verbatim. Read only to show and to
    # offer; nothing is scheduled on it. See docs/design/worker-channel.md § What a worker offers.
    field :harness, :map
    # What the machine last said about its own budget, cores and kinds, verbatim. Recorded and
    # not scheduled on: the row governs, so an operator's edit to a permanent worker survives a
    # reconnect. A report that disagrees with the row is shown rather than believed.
    field :reported, :map
    # Why this row never became a machine. A failed `create` used to return the driver's error
    # to the scheduler, which treats every error alike as *not right now* — so a node whose
    # image was misconfigured made and swept a row every few minutes for ever and looked idle
    # doing it. See `docs/design/worker-tier.md` § The provider driver.
    field :last_error, :string
    field :last_seen_at, :utc_datetime
    field :idle_since, :utc_datetime
    # Whether the platform may destroy this machine. False for one the operator provisioned;
    # see docs/design/worker-tier.md § Managed and unmanaged.
    field :managed, :boolean, default: true

    # **Provenance, not authority.** The recipe this machine was made from, whose values were
    # copied onto this row at creation and are never read back through
    # (`docs/design/provisioning.md` § Two tables). Null for a machine the operator built by
    # hand, which is the same row with its figures set by a person instead.
    belongs_to :template, Forge.Provisioning.Template
    belongs_to :provider_credential, Forge.Provisioning.Credential

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
      :cores,
      :accepts,
      :harness,
      :reported,
      :last_error,
      :last_seen_at,
      :idle_since,
      :managed,
      :template_id,
      :provider_credential_id
    ])
    |> validate_required([:provider, :status])
    # Zero is a real offer and not an error: `ForgeWorker.Config` reports nothing rather than
    # guessing when it cannot read `/proc/meminfo`, so the platform assigns the machine nothing,
    # which is visible. Negative is not an offer.
    |> validate_number(:memory_budget, greater_than_or_equal_to: 0)
    |> validate_number(:cores, greater_than_or_equal_to: 0)
  end
end
