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

  # **The one spelling of the sentinel.** Everything that has to recognise it —
  # `Forge.Workers`, the templates page — asks `latest?/1` rather than writing the string again,
  # so the day it changes there is one place to change it.
  @latest "latest"

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
    #
    # **Or the literal `latest`**, which names no snapshot and follows the mark instead
    # (`docs/design/provisioning.md` § Where a machine comes from).
    field :image, :string
    # The concrete snapshot this template is currently made from: the same value as `image` for
    # one naming a snapshot id, and the last resolution's answer for one naming `latest`. It is
    # what reaches the driver and what is written onto a machine's own row, so `workers.image` is
    # never the word `latest` — and it is what the failure counter and the protocol learning
    # compare a machine against.
    field :resolved_image, :string
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

  @doc """
  What a template's `image` holds to follow the mark rather than name a snapshot
  (`docs/design/provisioning.md` § Where a machine comes from).
  """
  @spec latest() :: String.t()
  def latest, do: @latest

  @doc """
  Whether this template follows the mark instead of naming one snapshot.

  Takes anything with an `image` — a row, or the attributes about to become one — because the
  page has to answer the question before a row exists.
  """
  @spec latest?(%{image: String.t() | nil}) :: boolean()
  def latest?(%{image: @latest}), do: true
  def latest?(%{image: _other}), do: false

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
      :resolved_image,
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
    |> resolve_concrete_image()
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

  # **A snapshot id resolves to itself, by construction rather than by care.** `resolved_image` is
  # what reaches the driver and what is written onto a machine, so a template naming an id whose
  # `resolved_image` had drifted from it would make machines from the wrong snapshot — and the
  # only thing that keeps the two together is that one save cannot change `image` without
  # changing this. A template naming `latest` names no snapshot, so what it resolves to is the
  # caller's: the catalogue's marked entry at save time, and `Forge.Workers`' fresh resolution at
  # every create (`docs/design/provisioning.md` § Where a machine comes from).
  defp resolve_concrete_image(changeset) do
    case fetch_change(changeset, :image) do
      {:ok, @latest} -> changeset
      {:ok, image} -> put_change(changeset, :resolved_image, image)
      :error -> changeset
    end
  end

  @doc """
  What is known of a template's snapshot once it is on `now`, having been on `was`: `offered` is
  what the provider's listing says about `now`, `stored` is what the row already holds, and the
  answer is the `{build, protocol}` to keep.

  **One rule, asked at both ends of the two ways a template moves between snapshots.**
  `changeset/2` asks it when a row is saved and `Forge.Provisioning.resolve_latest/2` when a
  create attempt resolves the mark, because both are handed a new concrete snapshot and whatever
  the catalogue says about it. Two copies of it were two places to disagree, and they did: the
  save decided by whether `image` changed, which for a template on the mark never does, so a
  rename after the mark had moved wrote the *old* snapshot's build and protocol onto the new one —
  and the next machine was made from an unprobed snapshot on a protocol nobody had verified.

  A listing says nothing about an unlabelled snapshot, so staying on the same one keeps what was
  learnt: forgetting the protocol a refused machine taught would earn that snapshot one more
  machine to refuse. Moving to a different one takes that one's labels, nothing included — a
  template moved off an image the platform refuses would otherwise go on refusing, and one moved
  onto a bad unlabelled image would keep the good one's protocol.
  """
  @type labels :: {String.t() | nil, non_neg_integer() | nil}
  @spec learnt(String.t() | nil, String.t() | nil, labels(), labels()) :: labels()
  def learnt(same, same, {build, protocol}, {was_build, was_protocol}),
    do: {build || was_build, protocol || was_protocol}

  def learnt(_was, _now, offered, _stored), do: offered

  # **A save does not forget what the platform knows about the snapshot it is already on**, and
  # does not carry what it knows onto a different one. `learnt/4` above is the rule and why; this
  # is where a save asks it, against the concrete snapshot rather than the template's `image` —
  # which for a template on the mark is the word and never moves.
  #
  # `resolved_image` itself is kept first, and only when the page said nothing: it cannot say
  # which snapshot carries the mark when none does, and reading that silence as *on no snapshot*
  # would unresolve a row that is on one.
  defp keep_what_was_learnt(changeset) do
    changeset = keep(:resolved_image, changeset)

    {build, protocol} =
      learnt(
        changeset.data.resolved_image,
        get_field(changeset, :resolved_image),
        {get_change(changeset, :image_build), get_change(changeset, :image_protocol)},
        {changeset.data.image_build, changeset.data.image_protocol}
      )

    changeset |> put_change(:image_build, build) |> put_change(:image_protocol, protocol)
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
      # **The concrete snapshot, never the word `latest`.** By the time a worker row is written
      # the template has been through `Forge.Workers`' resolution, so this is the id of the
      # snapshot the machine is actually made from (`provisioning.md` § Where a machine comes
      # from).
      image: template.resolved_image
    }
  end
end
