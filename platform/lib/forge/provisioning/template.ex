defmodule Forge.Provisioning.Template do
  @moduledoc """
  A recipe for creating a machine, and nothing else.

  `docs/design/provisioning.md` § Two tables, and the second is only a recipe: the values here
  are **copied** onto a worker at creation rather than read through it, so editing a template
  never resizes a machine that already exists and deleting one leaves its machines running.
  `workers.template_id` is provenance.

  `memory` and `cores` are what a machine made from this shape is *expected* to offer. They are
  what the platform plans with — which template to create for a queued job, and whether a
  declaration could ever fit — while what a running machine actually offers is on its own row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Forge.Jobs.Job

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "worker_templates" do
    belongs_to :user, Forge.Accounts.User
    belongs_to :provider_credential, Forge.Provisioning.Credential

    field :name, :string
    field :provider, :string
    field :size, :string
    # Opaque above the driver, like `size`. Null means the node's configured image, which is
    # what every template made before this column has.
    field :image, :string
    field :memory, :integer
    field :cores, :integer
    field :accepts, {:array, Ecto.Enum}, values: Job.kinds()
    field :max_workers, :integer, default: 1
    field :idle_ms, :integer

    # Consecutive machines this template failed to make, and the last reason. Disabled is
    # derived from the first rather than stored beside it — see `Forge.Provisioning.disabled?/1`
    # and `docs/design/provisioning.md` § A template that cannot make a working machine is taken
    # out of service. Neither is castable: they are the platform's record of what happened, not
    # something a form may set, and a form that could zero the counter would be a way to
    # re-enable a template by editing it.
    field :failures, :integer, default: 0
    field :last_error, :string

    has_many :project_templates, Forge.Provisioning.ProjectTemplate, foreign_key: :template_id
    has_many :projects, through: [:project_templates, :project]

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(template, attrs) do
    template
    |> cast(attrs, [
      :user_id,
      :provider_credential_id,
      :name,
      :provider,
      :size,
      :image,
      :memory,
      :cores,
      :accepts,
      :max_workers,
      :idle_ms
    ])
    |> validate_required([:user_id, :name, :provider, :memory, :cores, :max_workers])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_number(:memory, greater_than: 0)
    |> validate_number(:cores, greater_than: 0)
    # Zero is meaningful and is not "unlimited": a template the operator has turned off, which
    # `docs/design/worker-tier.md` § Managed and unmanaged already describes as the pure
    # permanent model — provision by hand and let the platform create nothing.
    |> validate_number(:max_workers, greater_than_or_equal_to: 0)
    |> validate_number(:idle_ms, greater_than: 0)
    |> validate_provider()
    |> validate_credential_provider()
    |> unique_constraint([:user_id, :name])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:provider_credential_id)
  end

  defp validate_provider(changeset) do
    validate_change(changeset, :provider, fn :provider, provider ->
      case Forge.Provider.driver(provider) do
        {:ok, _driver} -> []
        {:error, {:unknown_provider, _name}} -> [provider: "is not a provider this node knows"]
      end
    end)
  end

  # A template naming one provider and holding another's credential would create a machine in
  # the wrong account, or fail at the API with a message about a token rather than about the
  # row that is wrong. The two are checked together because neither is wrong alone.
  #
  # **And the credential must be the template owner's.** This checked the provider and nothing
  # else, so an id off the wire — the form only *offers* the caller's own, which is the page
  # again — made a template that created machines in somebody else's Hetzner account and billed
  # them for it. The same guard as `project_template` (`identity.md` § Workers): whose money a
  # template spends is its owner's to decide, and only its owner's.
  defp validate_credential_provider(changeset) do
    credential_id = get_field(changeset, :provider_credential_id)
    provider = get_field(changeset, :provider)
    owner = get_field(changeset, :user_id)

    case is_binary(credential_id) && Forge.Repo.get(Forge.Provisioning.Credential, credential_id) do
      false ->
        changeset

      %{user_id: ^owner, provider: ^provider} ->
        changeset

      %{user_id: ^owner, provider: other} ->
        add_error(changeset, :provider_credential_id, "is for #{other}, not #{provider}")

      _someone_elses_or_none ->
        add_error(changeset, :provider_credential_id, "is not one of your credentials")
    end
  end

  @doc """
  What a machine made from this template is created with.

  The values a worker row is given, all at once, so the copying happens in one place and a
  field added here cannot be forgotten at the call site.
  """
  @spec worker_attrs(t()) :: map()
  def worker_attrs(%__MODULE__{} = template) do
    %{
      provider: template.provider,
      template_id: template.id,
      user_id: template.user_id,
      provider_credential_id: template.provider_credential_id,
      memory_budget: template.memory,
      cores: template.cores,
      accepts: template.accepts
    }
  end
end
