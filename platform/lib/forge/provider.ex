defmodule Forge.Provider do
  @moduledoc """
  Where machines come from. A local VM under QEMU in the PoC, a Hetzner one after it, behind the
  same callbacks. See `docs/design/worker-tier.md` § The provider driver and
  `docs/design/provisioning.md` § Where a machine comes from.

  Nothing above this module knows the provider. A module outside `Forge.Provider.*` that
  matches on `"local"` is the bug these callbacks exist to prevent, and the second
  implementation is the test of whether it worked.

  **The driver is resolved per machine, not per node.** It used to be one configured module,
  which is what stood between this design and a fleet spanning two providers: a worker row
  carries the provider it was made by, a worker template carries the provider its credential is
  for, and the module is looked up from that name. Adding a provider is a line of config and a
  module implementing the behaviour; no code here learns its name.

  The store is not here. `docs/vision.md` gives a provider three jobs — create a machine,
  destroy it, and somewhere to put bytes — and the third is `Forge.Storage`'s, behind its own
  behaviour, because the operator's blobs are served by the platform either way.
  """

  @typedoc """
  What a machine is created with. `harness_env` is what the machine is given for its harness —
  the model, and no credential: a job brings its own in its assignment
  (`docs/design/credentials.md` § The credential belongs to the job, not to the machine).

  `size` is opaque above the driver: the platform passes the string a template carried and never
  reads it, which is what keeps `"cpx32"` from meaning anything outside the Hetzner driver.
  `credential` is the account the machine is made in, and is nil for a provider that needs none.
  """
  @type opts :: %{
          required(:worker_id) => String.t(),
          required(:token) => String.t(),
          required(:platform_url) => String.t(),
          optional(:harness_env) => [{String.t(), String.t()}],
          optional(:size) => String.t() | nil,
          optional(:image) => String.t() | nil,
          optional(:credential) => map() | nil
        }

  @type machine :: %{provider_id: String.t(), address: String.t() | nil}

  @typedoc """
  A machine this provider will sell, as the platform reads it.

  `size` is the driver's own name for it and is passed back verbatim in `opts.size`. Everything
  else is what the platform reasons about: `memory` and `cores` are what a template built on
  this shape should expect a machine to offer, and the price is what the operator is shown.
  """
  @type shape :: %{
          required(:size) => String.t(),
          required(:memory) => pos_integer(),
          required(:cores) => pos_integer(),
          optional(:price_hourly) => Decimal.t() | nil,
          optional(:currency) => String.t() | nil
        }

  @callback create(opts()) :: {:ok, machine()} | {:error, term()}

  @doc """
  Destroys the machine, in the account that pays for it.

  **The credential is a parameter because ending a machine is as much an account operation as
  making one**, and for a while it was not: `create` took the template's credential while
  `destroy` reached for a node-wide token that per-user credentials had replaced. On a node
  with no such token the Hetzner driver refused before sending anything, `Forge.Workers` threw
  the refusal away, and the row was marked destroyed while the machine kept running and
  billing — one leaked machine every sweep. See `docs/design/provisioning.md` § Whose account.
  """
  @callback destroy(String.t(), map() | nil) :: :ok | {:error, term()}

  @doc "What the provider says about the machine, asked with the credential that made it."
  @callback status(String.t(), map() | nil) ::
              {:ok, :pending | :running | :gone} | {:error, term()}

  @doc """
  The machine shapes this provider offers, for the credential given.

  A credential, because listing server types is an authenticated call on a real provider and
  because what is on offer can differ per account. A driver that needs none ignores it.
  """
  @callback shapes(map() | nil) :: {:ok, [shape()]} | {:error, term()}

  @typedoc """
  A machine this provider currently holds, as the provider sees it.

  Deliberately thin: this is for reconciling against `workers`, and the only field that has to
  line up is `provider_id`. Everything else is for a person reading the row.
  """
  @type instance :: %{
          required(:provider_id) => String.t(),
          required(:name) => String.t() | nil,
          required(:status) => String.t() | nil,
          optional(:created_at) => String.t() | nil
        }

  @doc """
  Every machine this credential's account holds that forge made.

  **Only forge's own**, which each driver decides for itself — the Hetzner one asks for the
  label it sets at create. Listing the operator's unrelated servers would turn a leak panel
  into a list of things that are fine.

  **A driver that paginates follows it to the end.** A truncated answer here reports *no
  orphans* while billing for the ones on the next page, which is worse than no panel at all.
  """
  @callback list(map() | nil) :: {:ok, [instance()]} | {:error, term()}

  @spec list(String.t(), map() | nil) :: {:ok, [instance()]} | {:error, term()}
  def list(provider, credential \\ nil) do
    with {:ok, driver} <- driver(provider), do: driver.list(credential)
  end

  @doc """
  The provider id of the machine this driver made for `worker_id`, if it holds one; nil if not.

  **What a row that never heard its create's answer is destroyed by**
  (`docs/design/provisioning.md` § Whose account). The id reaches the row only when the create
  returns, and a platform stopped mid-create leaves a machine billing under a row with no
  `provider_id`. Each driver finds it by the name it gave the machine at create, which is the
  worker id in some form, so no guess is involved and nothing that is not forge's can match. An
  error — the provider not answering, or the driver unable to ask — keeps the row as a refused
  destroy does; nil is the provider saying there is no such machine.
  """
  @callback find(String.t(), map() | nil) :: {:ok, String.t() | nil} | {:error, term()}

  @spec find(String.t(), String.t(), map() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def find(provider, worker_id, credential \\ nil) do
    with {:ok, driver} <- driver(provider), do: driver.find(worker_id, credential)
  end

  @typedoc """
  An image a machine can be made from, as the platform reads it.

  `id` is opaque above the driver and is what a template stores and `opts.image` carries back.
  Everything else is for a person choosing between them in a form.
  """
  @type image :: %{
          required(:id) => String.t(),
          required(:name) => String.t() | nil,
          optional(:status) => String.t() | nil,
          optional(:created) => String.t() | nil,
          # What the snapshot carries, from its labels where the driver has them: the worker
          # build and the channel protocol it speaks. Nil is unlabelled — unknown, not compatible
          # (`docs/design/provisioning.md` § A snapshot that speaks the wrong protocol).
          optional(:build) => String.t() | nil,
          optional(:protocol) => non_neg_integer() | nil
        }

  @doc """
  The images this credential can make a machine from.

  **Hetzner has no image upload**, so what this lists are snapshots the operator has already
  made by hand — boot a rescue server, write the disk, snapshot it, throw the server away
  (`docs/design/worker-tier.md` § Updating a worker). The platform offers what is there and
  never makes one.
  """
  @callback images(map() | nil) :: {:ok, [image()]} | {:error, term()}

  @spec images(String.t(), map() | nil) :: {:ok, [image()]} | {:error, term()}
  def images(provider, credential \\ nil) do
    with {:ok, driver} <- driver(provider), do: driver.images(credential)
  end

  @doc """
  The fields this provider's credential is made of, in the order a form should ask for them.

  The secret is a map whose shape the driver owns
  (`docs/design/provisioning.md` § Whose account), and a form has to know what to ask for —
  one token for Hetzner, a key pair elsewhere. Declaring it here is what keeps that knowledge
  in the driver rather than in a `case` in a LiveView, which is the same boundary `shapes/1`
  draws for machine sizes.

  An empty list means this provider needs no credential at all, which is the local driver.
  """
  @callback credential_fields() :: [%{key: String.t(), label: String.t()}]

  @spec credential_fields(String.t()) :: [%{key: String.t(), label: String.t()}]
  def credential_fields(provider) do
    case driver(provider) do
      {:ok, module} -> module.credential_fields()
      {:error, _reason} -> []
    end
  end

  @doc """
  Which of a template's opaque fields this provider cannot make a machine without.

  `size` and `image` mean nothing above the driver, so only the driver can say that a template
  naming neither is useless to it. Hetzner needs both; the local driver needs neither, because
  it boots this host's image at this host's size whatever a template says.
  `Forge.Provisioning.Template.changeset/2` requires what is listed, so such a template is
  refused where it is typed rather than saved, assigned, and then failing at its first create
  (`docs/design/provisioning.md` § Where a machine comes from).

  Declared here, like `credential_fields/0`, so that no code above the driver compares a
  provider's name to find out.
  """
  @callback required_template_fields() :: [:size | :image]

  @spec required_template_fields(String.t()) :: [:size | :image]
  def required_template_fields(provider) do
    case driver(provider) do
      {:ok, module} -> module.required_template_fields()
      # An equivalent mutant, whatever it answers. A template naming a provider this node does
      # not have is already refused by `Template.changeset/2`, so requiring more of it only adds
      # errors to a changeset that cannot be saved. The page can reach it — the create form
      # offers only `names/0`, but the edit form takes the provider from the stored template,
      # which may name one the node no longer has — and draws nothing from the answer: with no
      # driver there is no catalogue, so size and image are free text, and the blank choice this
      # list words ("choose one" or the default) is the one thing it decides, on a select that
      # is not there.
      {:error, _reason} -> []
    end
  end

  @doc """
  How long this provider bills a machine for at a time, in milliseconds, when every started
  increment is charged whole — counted from when the machine was made. Nil for a provider that
  bills nothing, or bills by use so finely that when a machine goes does not matter.

  **It decides when an idle machine goes.** Hetzner charges every hour a server has started, so an
  idle one destroyed ten minutes into its hour threw away fifty minutes it had paid for; with an
  increment, `Forge.Workers.goes_at/2` decides on a machine only at the leeway point before each
  increment ends (`docs/design/worker-tier.md` § The hour already paid for).
  """
  @callback billed_increment_ms() :: pos_integer() | nil

  @spec billed_increment_ms(String.t() | nil) :: pos_integer() | nil
  def billed_increment_ms(provider) do
    case driver(provider) do
      {:ok, module} -> module.billed_increment_ms()
      # A row naming a provider this node does not have cannot be destroyed from here at all
      # (`Forge.Workers.destroy/2` retires it), so nothing is gained by waiting for an hour of a
      # bill nobody can read: it goes at its period.
      {:error, _reason} -> nil
    end
  end

  @doc """
  Creates a machine. The driver comes from `opts.provider`, or the default when it says nothing.
  """
  @spec create(opts()) :: {:ok, machine()} | {:error, term()}
  def create(opts) do
    with {:ok, driver} <- driver(Map.get(opts, :provider)), do: driver.create(opts)
  end

  @spec destroy(String.t(), String.t(), map() | nil) :: :ok | {:error, term()}
  def destroy(provider, provider_id, credential \\ nil) do
    with {:ok, driver} <- driver(provider), do: driver.destroy(provider_id, credential)
  end

  @spec status(String.t(), String.t(), map() | nil) ::
          {:ok, :pending | :running | :gone} | {:error, term()}
  def status(provider, provider_id, credential \\ nil) do
    with {:ok, driver} <- driver(provider), do: driver.status(provider_id, credential)
  end

  @spec shapes(String.t(), map() | nil) :: {:ok, [shape()]} | {:error, term()}
  def shapes(provider, credential \\ nil) do
    with {:ok, driver} <- driver(provider), do: driver.shapes(credential)
  end

  @doc """
  The module that speaks for `provider`.

  **An unknown name is an error and never the default.** A worker row naming a provider this
  node no longer has configured is a machine nothing can destroy, and silently reaching for
  whatever is configured instead would destroy somebody else's.
  """
  @spec driver(String.t() | nil) :: {:ok, module()} | {:error, {:unknown_provider, String.t()}}
  def driver(nil), do: driver(default())

  def driver(provider) when is_binary(provider) do
    case Map.fetch(drivers(), provider) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_provider, provider}}
    end
  end

  @doc "Every provider name this node can speak to."
  @spec names() :: [String.t()]
  def names, do: drivers() |> Map.keys() |> Enum.sort()

  @doc """
  The provider a machine is made by when nothing names one.

  A worker template names its own; this is what `mix forge.worker.new` records for a machine
  the operator built by hand, and the driver for anything that names none. It is never a
  reason to create a machine — there is no node fallback (`docs/design/provisioning.md`
  § Whose account).
  """
  @spec default() :: String.t()
  def default, do: config(:default, "local")

  defp drivers, do: config(:drivers, %{"local" => Forge.Provider.LocalVm})

  @doc false
  def config(key, default),
    do: :forge |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
