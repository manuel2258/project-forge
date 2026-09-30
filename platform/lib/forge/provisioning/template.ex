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
  alias Forge.Provisioning.Credential

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "worker_templates" do
    belongs_to :user, Forge.Accounts.User
    belongs_to :provider_credential, Credential

    field :name, :string
    field :provider, :string
    field :size, :string
    # Opaque above the driver, like `size`. Null leaves it to the driver: the local one boots
    # this host's image whatever a template says, and one that lists `:image` in
    # `Forge.Provider.required_template_fields/1` — Hetzner — refuses a template without one,
    # here on save and at create for a row saved before that rule.
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

    # What the chosen snapshot carries: the worker build and the channel protocol, from its
    # provider labels when the template is saved, or the protocol learnt when a machine made from
    # it was refused at join. Null is *unlabelled* — unknown, not compatible
    # (`docs/design/provisioning.md` § A snapshot that speaks the wrong protocol).
    field :image_build, :string
    field :image_protocol, :integer

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
      :idle_ms,
      :image_build,
      :image_protocol
    ])
    # **No kinds is nil, never `[]`.** Both mean "takes anything" (`holds?/2` in
    # `Forge.Provisioning`), and a second spelling of it made an edit from one to the other look
    # like a change to what the template could hold, which brings back stuck tickets
    # (`Forge.Provisioning.update_template/3`) for nothing. Back to what the row already holds, the
    # change is dropped.
    |> update_change(:accepts, fn
      [] -> nil
      kinds -> kinds
    end)
    |> validate_required([:user_id, :name, :provider, :memory, :cores, :max_workers])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_number(:memory, greater_than: 0)
    |> validate_number(:cores, greater_than: 0)
    # Zero is meaningful and is not "unlimited": a template the operator has turned off, so the
    # platform creates nothing from it — the pure permanent model of
    # `docs/design/worker-tier.md` § Managed and unmanaged, one template at a time.
    |> validate_number(:max_workers, greater_than_or_equal_to: 0)
    |> validate_number(:idle_ms, greater_than: 0)
    |> validate_provider()
    |> validate_required_by_driver()
    |> validate_credential_provider()
    |> keep_what_was_learnt()
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

  # `size` and `image` are opaque here, so whether a template may leave one blank is the
  # driver's to say. Asked of the provider the template now names, on create and on edit alike:
  # a Hetzner template saved before this rule cannot be renamed without being given an image,
  # which is the edit that makes it work.
  defp validate_required_by_driver(changeset) do
    case get_field(changeset, :provider) do
      provider when is_binary(provider) ->
        validate_required(changeset, Forge.Provider.required_template_fields(provider))

      # An equivalent mutant, whatever this clause asks: a template naming no provider is
      # already refused by `validate_required/2` above, so anything added here is a second
      # error on a changeset that cannot be saved.
      _none ->
        changeset
    end
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

    case is_binary(credential_id) &&
           mismatch(Forge.Repo.get(Credential, credential_id), changeset, provider) do
      nothing when nothing in [false, nil] ->
        changeset

      :not_owner ->
        add_error(changeset, :provider_credential_id, "is not one of your credentials")

      {:wrong_provider, theirs} ->
        add_error(changeset, :provider_credential_id, "is for #{theirs}, not #{provider}")
    end
  end

  # An id naming no credential reads as somebody else's: from outside the two cannot be told
  # apart, and the answer should not tell them apart either.
  defp mismatch(nil, _changeset, _provider), do: :not_owner

  defp mismatch(%Credential{} = credential, changeset, provider),
    do: credential_mismatch(get_field(changeset, :user_id), provider, credential)

  @doc """
  What is wrong with a template owned by `user_id` and naming `provider` holding `credential`,
  or nil when nothing is.

  **One definition, asked at both ends of a template's life.** `changeset/2` asks it when a row
  is written; `Forge.Provisioning.spendable_credential/1` asks it again when a machine is about
  to be made, because a row saved before the changeset checked anything still names whatever
  credential it was given. Two copies of the rule would be two places for it to disagree.
  """
  @spec credential_mismatch(Ecto.UUID.t() | nil, String.t() | nil, Credential.t()) ::
          nil | :not_owner | {:wrong_provider, String.t()}
  def credential_mismatch(user_id, provider, %Credential{} = credential) do
    cond do
      credential.user_id != user_id ->
        :not_owner

      # `is_binary/1` is an equivalent mutant for whether a row is saved or a machine made: a nil
      # provider already fails `validate_required` in the changeset, and
      # `worker_templates.provider` is `null: false` for a row read at creation. Dropping it adds
      # a second error — "is for hetzner, not " — to a changeset already refused, which a test
      # could see but no user would.
      is_binary(provider) and credential.provider != provider ->
        {:wrong_provider, credential.provider}

      true ->
        nil
    end
  end

  # **A save does not forget what the platform knows about the image it already names.** The
  # labels are read from the provider's listing on every save, and an unlabelled snapshot reads
  # as nothing there — so a rename of a template whose protocol was learnt from a refused machine
  # would reset it to unknown, and earn the snapshot one more machine to refuse. With the image
  # unchanged, only a label that is actually there replaces what is stored; choosing another
  # image takes that image's labels, nothing included.
  defp keep_what_was_learnt(changeset) do
    if Map.has_key?(changeset.changes, :image),
      do: changeset,
      else: Enum.reduce([:image_build, :image_protocol], changeset, &keep/2)
  end

  defp keep(field, changeset) do
    case Map.fetch(changeset.changes, field) do
      {:ok, nil} -> delete_change(changeset, field)
      _kept -> changeset
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
      accepts: template.accepts,
      image: template.image
    }
  end
end
