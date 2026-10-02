defmodule Forge.Workers.Worker do
  @moduledoc """
  A machine that hosts jobs: created on demand, destroyed after an idle period, and recorded
  from before it exists until after it is gone. See `docs/design/worker-tier.md`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias ForgeCore.Workflow.Resources

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
    # Asked to be made and not yet answered; see the migration that added it, and
    # `docs/design/provisioning.md` § Whose account.
    field :unanswered_create, :boolean, default: false

    # What the machine said at its last join, refused or not (`docs/design/worker-channel.md`
    # § Versions): the release string it logs, the twelve-character build of its store path, and
    # the protocol it speaks — 0 for a release too old to say. All null until it joins.
    field :release, :string
    field :build, :string
    field :protocol, :integer
    # The image this machine was made from, copied from its template like its figures. What a
    # refused machine teaches its template is about this image, not whatever the template names
    # by then (`docs/design/provisioning.md` § A snapshot that speaks the wrong protocol).
    field :image, :string

    # **The machine's own word that it can run nothing** — its systemd stopped answering — and
    # when the platform last told it to reboot (`docs/design/worker-tier.md` § A machine whose
    # systemd stops answering). A row with `unhealthy_at` set is assignable to nothing; a join
    # without the word clears it. `rebooted_at` outlives the episode: it is the hour.
    field :unhealthy_at, :utc_datetime_usec
    field :unhealthy_reason, :string
    field :rebooted_at, :utc_datetime_usec

    # **Provenance, not authority.** The recipe this machine was made from, whose values were
    # copied onto this row at creation and are never read back through
    # (`docs/design/provisioning.md` § Two tables). Null for a machine the operator built by
    # hand, which is the same row with its figures set by a person instead.
    belongs_to :template, Forge.Provisioning.Template
    belongs_to :provider_credential, Forge.Provisioning.Credential

    # Whose machine this is: its template's owner, or whoever provisioned it by hand. Only the
    # owner assigns it to projects (`docs/design/identity.md` § Workers). Null only on rows no
    # rule could give an owner, which take no work.
    belongs_to :user, Forge.Accounts.User
    has_many :project_workers, Forge.Workers.ProjectWorker

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
      :release,
      :build,
      :protocol,
      :image,
      :unhealthy_at,
      :unhealthy_reason,
      :rebooted_at,
      :unanswered_create,
      :template_id,
      :provider_credential_id,
      :user_id
    ])
    |> validate_required([:provider, :status])
    |> validate_offer()
  end

  @doc """
  What a person may set on a machine: what it offers the gate, and nothing else.

  `changeset/2` casts every field the row has — status, token hash, `managed` — because the
  platform's own writes need them. A form does not, and a changeset that cast them would let one
  more field in the params turn a permanent machine into one the platform may destroy. Both
  figures are required: this is how an operator *sets* what a machine offers, and a blank would
  silently un-gate the machine it was meant to correct (`docs/design/provisioning.md` § What a
  worker offers).
  """
  def offer_changeset(worker, attrs) do
    worker
    |> cast(attrs, [:memory_budget, :cores, :accepts])
    |> validate_required([:memory_budget, :cores])
    |> validate_offer()
    # Less than one job's worth is a figure no job fits, and a machine its owner wants to take
    # nothing is one assigned to no project (`Workers.serving/1`): an empty `accepts` takes
    # anything. The machine's own report may still be zero (below): it says it could not read its
    # memory, which is not a figure somebody typed.
    |> validate_number(:memory_budget,
      greater_than_or_equal_to: Resources.minimum_memory(),
      message: Resources.too_little_memory()
    )
  end

  # Zero is a real offer and not an error: `ForgeWorker.Config` reports nothing rather than
  # guessing when it cannot read `/proc/meminfo`, so the platform assigns the machine nothing,
  # which is visible. Negative is not an offer.
  defp validate_offer(changeset) do
    changeset
    |> validate_number(:memory_budget, greater_than_or_equal_to: 0)
    |> validate_number(:cores, greater_than_or_equal_to: 0)
  end
end
