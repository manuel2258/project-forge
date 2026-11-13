defmodule Forge.Harness do
  @moduledoc """
  The harnesses this node can fund, and what the platform needs to know about each.

  `ForgeWorker.Harness` is the other half and runs the thing; this half only knows what a
  credential for it looks like and how to ask the provider whether one works
  (`docs/design/credentials.md` § Checked on save). A second harness is a module implementing
  this behaviour and a line in the registry, and a credential names which one it is for.
  """

  @typedoc "One model a credential may use, as the provider named it."
  @type model :: %{String.t() => String.t()}

  @typedoc """
  Why a check did not accept a credential. `:refused` means the provider answered and said no;
  `{:unreachable, phrase}` means it did not answer usefully, and `{:malformed, phrase}` that the
  secret has the wrong shape (for a harness checked by shape alone); the phrase is fixed text the
  driver chose — **never** anything derived from the request or the secret.
  """
  @type failure :: :refused | {:unreachable, String.t()} | {:malformed, String.t()}

  @doc "The harness's own name, for a person."
  @callback label() :: String.t()

  @doc "The kinds of secret it takes, each with a label for a person, in the order to offer them."
  @callback kinds() :: [{String.t(), String.t()}]

  @typedoc """
  What a kind of credential declares (`docs/design/credentials.md` § One mechanism, differences
  declared per kind): whether at most one run may hold it at a time, whether a run hands it back
  changed, and whether it is checked against the provider on save or only by its shape.
  """
  @type traits :: %{exclusive: boolean(), returns: boolean(), checked: :provider | :shape}

  @doc "What a kind declares."
  @callback traits(kind :: String.t()) :: traits()

  @doc """
  What the secret itself says of whose it is, for a row and for comparing a returned copy:
  `%{account_id: ..., plan: ...}`, or nothing. Display and comparison only.
  """
  @callback attributes(kind :: String.t(), secret :: map()) :: map()

  @optional_callbacks attributes: 2

  @doc """
  Asks the provider whether this secret works and which models it may use. Must never raise and
  must never put the secret, or anything carrying it, into what it returns.
  """
  @callback check(kind :: String.t(), secret :: map()) :: {:ok, [model()]} | {:error, failure()}

  @unknown_kind %{exclusive: false, returns: false, checked: :provider}

  @doc "The driver for a harness name."
  @spec driver(String.t() | nil) :: {:ok, module()} | {:error, :unknown_harness}
  def driver(name) do
    case Map.fetch(drivers(), name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_harness}
    end
  end

  @doc "Every harness this node knows, by name."
  @spec names() :: [String.t()]
  def names, do: drivers() |> Map.keys() |> Enum.sort()

  @doc "What the secret says of itself, by the driver's `attributes/2` where it has one."
  @spec attributes(module(), String.t(), map()) :: map()
  def attributes(module, kind, secret) do
    Code.ensure_loaded(module)
    if function_exported?(module, :attributes, 2), do: module.attributes(kind, secret), else: %{}
  end

  @doc "What a kind of a harness's credential declares; a kind nobody knows declares nothing."
  @spec traits(String.t() | nil, String.t() | nil) :: traits()
  def traits(name, kind) do
    with {:ok, module} <- driver(name),
         true <- Enum.any?(module.kinds(), &(elem(&1, 0) == kind)) do
      module.traits(kind)
    else
      _unknown -> @unknown_kind
    end
  end

  @doc "The kinds of secret a harness takes, or none for a harness this node does not know."
  @spec kinds(String.t() | nil) :: [{String.t(), String.t()}]
  def kinds(name) do
    case driver(name) do
      {:ok, module} -> module.kinds()
      {:error, :unknown_harness} -> []
    end
  end

  @doc "A harness's name for a person, falling back to the name itself."
  @spec label(String.t()) :: String.t()
  def label(name) do
    case driver(name) do
      {:ok, module} -> module.label()
      {:error, :unknown_harness} -> name
    end
  end

  @doc "What a kind of secret is called, for a person."
  @spec kind_label(String.t(), String.t()) :: String.t()
  def kind_label(name, kind) do
    case List.keyfind(kinds(name), kind, 0) do
      {^kind, label} -> label
      nil -> kind
    end
  end

  # A literal and not configuration: nothing needs to swap a harness out, and an
  # indirection with no reader is a claim nothing checks. A second harness is a line here.
  defp drivers,
    do: %{"claude_code" => Forge.Harness.ClaudeCode, "codex" => Forge.Harness.Codex}
end
