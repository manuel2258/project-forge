defmodule ForgeCore.Workflow.Resources do
  @moduledoc """
  What a job asks the scheduler for: a memory ceiling and a number of cores.

  `docs/design/workflow-grammar-v1.md` § Resources holds the grammar,
  `docs/design/commands.md` § Resources the reasoning, and
  `docs/design/provisioning.md` what the platform does with it. In short: `memory` is the
  slice's hard ceiling and what the gate counts, `cpu` is how many cores the gate *reserves*
  — a reservation and not a quota, because capping a slice would throw away the proportional
  CPU sharing `docs/decisions.md` chose.

  A field is nil when the level that could have declared it did not, which is what makes
  `resolve/1` a chain rather than a merge of complete values. The last link is the platform's
  configured slice, and that lives in the platform: `forge_core` has no configuration.
  """

  @enforce_keys []
  defstruct [:memory, :cpu]

  @type t :: %__MODULE__{memory: pos_integer() | nil, cpu: pos_integer() | nil}

  # Binary units only. `MB` and `MiB` differ by 4.9% and an operator who means one and types
  # the other gets a silently wrong ceiling; there is no reading of a memory size where the
  # decimal form is what someone wanted, so it is refused by name rather than accepted as an
  # approximation. A bare integer is bytes.
  @units %{
    "B" => 1,
    "KiB" => 1024,
    "MiB" => 1024 * 1024,
    "GiB" => 1024 * 1024 * 1024,
    "TiB" => 1024 * 1024 * 1024 * 1024
  }

  @decimal %{"KB" => "KiB", "MB" => "MiB", "GB" => "GiB", "TB" => "TiB"}

  @doc """
  Parses a byte size: a positive integer, or a positive integer and a binary unit.

  Returns `{:error, {:decimal_unit, suggestion}}` for `4GB` and friends, so the caller can say
  which unit was meant instead of "must be a byte size".
  """
  @spec parse_bytes(term()) ::
          {:ok, pos_integer()} | {:error, {:decimal_unit, String.t()}} | :error
  def parse_bytes(value) when is_integer(value) and value > 0, do: {:ok, value}

  def parse_bytes(value) when is_binary(value) do
    # **The unit is optional, and leaving it out must mean what a bare integer means.** It did
    # not: `512` was accepted and `"512"` was refused, so a form — where every field is a
    # string — could not carry a plain byte count at all, and a YAML author who quoted the
    # number got a different answer from one who did not.
    case Regex.run(~r/^\s*(\d+)\s*([A-Za-z]*)\s*$/, value) do
      [_all, digits, ""] -> parse_bytes(String.to_integer(digits))
      [_all, digits, unit] -> with_unit(String.to_integer(digits), unit)
      _other -> :error
    end
  end

  def parse_bytes(_value), do: :error

  # Built once at compile time so a unit is matched without regard to case: `4gib` is
  # unambiguous and refusing it would be pedantry. The `i` still separates the two families
  # after downcasing — `mib` is not `mb` — so this loses none of the distinction above.
  @lookup Map.new(@units, fn {unit, multiplier} -> {String.downcase(unit), multiplier} end)
  @decimal_lookup Map.new(@decimal, fn {unit, binary} -> {String.downcase(unit), binary} end)

  defp with_unit(0, _unit), do: :error

  defp with_unit(count, unit) do
    folded = String.downcase(unit)

    cond do
      multiplier = Map.get(@lookup, folded) -> {:ok, count * multiplier}
      binary = Map.get(@decimal_lookup, folded) -> {:error, {:decimal_unit, binary}}
      true -> :error
    end
  end

  @doc """
  A byte count as the largest binary unit that divides it exactly, or the bare number.

  For putting a figure back in front of a person: a form that offers `8GiB` and then fills
  itself with `8589934592` is a form arguing with its own label, and the number it wrote is the
  one nobody would type.
  """
  @spec humanize(pos_integer()) :: String.t()
  def humanize(bytes) when is_integer(bytes) and bytes > 0 do
    # Total by construction: `B` is a unit with a multiplier of one, so the search always finds
    # something and a size no larger unit divides comes back in bytes. A fallback here would be
    # a branch nothing could ever reach.
    {unit, multiplier} =
      @units
      |> Enum.sort_by(fn {_unit, multiplier} -> -multiplier end)
      |> Enum.find(fn {_unit, multiplier} -> rem(bytes, multiplier) == 0 end)

    "#{div(bytes, multiplier)}#{unit}"
  end

  @doc """
  A byte count as gibibytes to one decimal — `7.5 GiB` — for reading rather than for typing back,
  which is `humanize/1`'s job; nil, a figure nobody has, is a dash rather than a zero. The one
  copy the workers page, the templates page and a machine's log all draw with.
  """
  @spec gib(non_neg_integer() | nil) :: String.t()
  def gib(nil), do: "—"
  def gib(bytes), do: :erlang.float_to_binary(bytes / 1024 ** 3, decimals: 1) <> " GiB"

  @doc "The units a byte size may carry, for an error message that says what is accepted."
  @spec units() :: [String.t()]
  def units, do: @units |> Map.keys() |> Enum.sort_by(&byte_size/1)

  @doc """
  The first declaration of each field, nearest first.

  Nil entries are skipped, so a caller passes the whole chain — the command's, the state's,
  the workflow's defaults — without checking which levels exist. A field absent from every
  level stays nil and the platform supplies it.
  """
  @spec resolve([t() | nil]) :: t()
  def resolve(chain) do
    chain
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%__MODULE__{}, fn declared, acc ->
      %__MODULE__{
        memory: acc.memory || declared.memory,
        cpu: acc.cpu || declared.cpu
      }
    end)
  end
end
