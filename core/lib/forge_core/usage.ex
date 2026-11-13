defmodule ForgeCore.Usage do
  @moduledoc """
  What a run used, as **weighted tokens**: its tokens by kind, weighted, the same weights for every
  model and every harness (`docs/design/capacity.md` § Usage in weighted tokens). Nothing else in
  the code holds a weight.

  Tokens are a map of `:input` (fresh), `:cache_write`, `:cache_read` and `:output` (reasoning
  included), each a non-negative integer. Weights are held in hundredths so the arithmetic is
  integer: a process's usage is `div(sum + 50, 100)`, rounded once over all its calls and not per call.
  (A job that runs more than one process, as a correction does, adds their rounded figures.)

  A dollar figure enters only through `from_dollars/1`, at the placeholder rate `per_dollar/0`, to
  convert old figures once.
  """

  @kinds [:input, :cache_write, :cache_read, :output]

  # Hundredths of a weighted token per token: 1, 1.25, 0.1 and 5.
  @weights %{input: 100, cache_write: 125, cache_read: 10, output: 500}

  # A placeholder like `window_tokens`, said so in capacity.md: $5 per million fresh input tokens
  # (an Opus-class price) at weight 1. Migrations write their own copy of it as a literal.
  @per_dollar 200_000

  @type kind :: :input | :cache_write | :cache_read | :output
  @type tokens :: %{optional(kind()) => non_neg_integer()}

  # A thousand trillion weighted tokens: far past any real budget, and a long way under the
  # `bigint` (about 9.2e18) every figure here is stored in.
  @max 1_000_000_000_000_000

  @doc "The most weighted tokens any limit, budget or figure may be."
  @spec max() :: pos_integer()
  def max, do: @max

  @doc "The kinds of token a run is counted in, in the order they are drawn."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The weight of each kind in hundredths of a weighted token."
  @spec weights() :: %{kind() => pos_integer()}
  def weights, do: @weights

  @doc "Weighted tokens to the dollar: the rate old dollar figures are converted at."
  @spec per_dollar() :: pos_integer()
  def per_dollar, do: @per_dollar

  @doc "A token map with every kind present and zero."
  @spec empty() :: %{kind() => 0}
  def empty, do: Map.new(@kinds, &{&1, 0})

  @doc "The weighted tokens of `tokens`. A kind that is absent counts as zero."
  @spec weigh(tokens()) :: non_neg_integer()
  def weigh(tokens) when is_map(tokens) do
    sum =
      Enum.reduce(@weights, 0, fn {kind, weight}, acc -> acc + count(tokens, kind) * weight end)

    div(sum + 50, 100)
  end

  @doc "Two token maps added kind by kind."
  @spec add(tokens(), tokens()) :: %{kind() => non_neg_integer()}
  def add(a, b), do: Map.new(@kinds, &{&1, count(a, &1) + count(b, &1)})

  @doc """
  A token map from a stored or wire map, whose keys may be strings. Unknown keys are dropped and
  anything that is not a non-negative integer counts as zero.
  """
  @spec normalize(map() | nil) :: %{kind() => non_neg_integer()}
  def normalize(map) when is_map(map), do: Map.new(@kinds, &{&1, count(map, &1)})
  def normalize(_), do: empty()

  @doc """
  Weighted tokens for a dollar figure, at `per_dollar/0`, and never more than `max/0`: a figure
  from a stored spec or a workflow that is past what the `bigint` columns hold is held there
  rather than overflowing the multiplication or the insert.
  """
  @spec from_dollars(number()) :: non_neg_integer()
  def from_dollars(dollars)
      when is_number(dollars) and dollars >= 0 and dollars > @max / @per_dollar,
      do: @max

  def from_dollars(dollars) when is_number(dollars) and dollars >= 0,
    do: round(dollars * @per_dollar)

  @doc """
  Parses `800k`, `4M`, `84.2M` or a plain integer (as an integer or a string) into weighted tokens.
  """
  @spec parse(term()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def parse(value) when is_integer(value) and value >= 0 and value <= @max, do: {:ok, value}

  def parse(value) when is_binary(value) do
    # Checked before the multiplication, not after: `1e308M` overflows a float and raises, and a
    # figure past `@max` does not fit the `bigint` columns it is stored in.
    with {number, suffix} <- Float.parse(String.trim(value)),
         {:ok, multiplier} <- multiplier(suffix),
         true <- number >= 0 and number <= @max / multiplier do
      {:ok, round(number * multiplier)}
    else
      _ -> {:error, "must be a number of weighted tokens such as 800k, 4M or 84.2M"}
    end
  end

  def parse(_), do: {:error, "must be a number of weighted tokens such as 800k, 4M or 84.2M"}

  defp multiplier(""), do: {:ok, 1}
  defp multiplier("k"), do: {:ok, 1_000}
  defp multiplier("M"), do: {:ok, 1_000_000}
  defp multiplier(_), do: :error

  @doc """
  Weighted tokens as `parse/1` reads them: `800k`, `4M`, `84.2M`, else the whole number. Only a
  figure that a suffix states exactly is abbreviated, so `format/1` never loses a digit.
  """
  @spec format(non_neg_integer()) :: String.t()
  def format(n) when is_integer(n) and n >= 1_000_000 and rem(n, 100_000) == 0,
    do: "#{trim(n / 1_000_000)}M"

  def format(n) when is_integer(n) and n >= 1_000 and rem(n, 1_000) == 0,
    do: "#{div(n, 1_000)}k"

  def format(n) when is_integer(n), do: Integer.to_string(n)

  defp trim(float) do
    text = :erlang.float_to_binary(float, decimals: 1)
    if String.ends_with?(text, ".0"), do: binary_part(text, 0, byte_size(text) - 2), else: text
  end

  defp count(map, kind) do
    case Map.get(map, kind, Map.get(map, Atom.to_string(kind))) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end
end
