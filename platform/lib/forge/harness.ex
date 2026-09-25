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
  `{:unreachable, phrase}` means it did not answer usefully, and the phrase is fixed text the
  driver chose — **never** anything derived from the request, whose headers are the secret.
  """
  @type failure :: :refused | {:unreachable, String.t()}

  @doc "The harness's own name, for a person."
  @callback label() :: String.t()

  @doc "The kinds of secret it takes, each with a label for a person, in the order to offer them."
  @callback kinds() :: [{String.t(), String.t()}]

  @doc """
  Asks the provider whether this secret works and which models it may use. Must never raise and
  must never put the secret, or anything carrying it, into what it returns.
  """
  @callback check(kind :: String.t(), secret :: map()) :: {:ok, [model()]} | {:error, failure()}

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
  defp drivers, do: %{"claude_code" => Forge.Harness.ClaudeCode}
end
