defmodule ForgeCore.WorkerProtocol do
  @moduledoc """
  The version of the worker channel protocol this build speaks, and the range the platform
  accepts. `docs/design/worker-channel.md` § Versions.

  **One number, in one file.** `core/priv/worker_protocol` is read here at compile time and by
  `flake.nix` with `builtins.readFile`, which is how `bin/hetzner-image` labels a snapshot; the
  worker sends it in its join and the platform checks it, both through this module. Nothing
  else may write the current number down, and `ForgeCore.WorkerProtocolTest` fails if `flake.nix`
  stops reading the file. A version something *arrived in* is a different fact, fixed once it is
  true — the platform's `@commands_protocol` is one — and does not move when this does.

  **It moves only for a breaking change** — `worker-channel.md` § What needs a bump says which
  those are. An addition the other side may ignore is not one: a platform refuses a worker newer
  than itself, so a bump for an addition would turn away a snapshot built from a newer checkout
  for a field its platform could simply have ignored.
  """

  @path Path.join(__DIR__, "../../priv/worker_protocol")
  @external_resource @path
  @current @path |> File.read!() |> String.trim() |> String.to_integer()

  # **The oldest protocol this platform still accepts.** A worker that sends none is protocol 0,
  # every release before the field existed; this started at 0 so that shipping the check refused
  # nobody, and is 4 from release 0.7.0, when no machine outside the operator's own ran an older
  # worker. Raising it refuses running machines — managed ones are destroyed on their next join —
  # so it is made after every template and permanent machine has moved (`worker-channel.md`
  # § What needs a bump, and raising the minimum). It is code and not the file on purpose: the
  # file is what this build speaks, this is what it still hears.
  @minimum 4

  @doc "The protocol this build speaks."
  @spec current() :: non_neg_integer()
  def current, do: @current

  @doc "The oldest protocol this build accepts from the other side."
  @spec minimum() :: non_neg_integer()
  def minimum, do: @minimum

  @doc """
  Whether a platform built from this accepts a worker speaking `protocol`: `minimum <= P <=
  current`, and nothing that is not an integer. A newer worker is refused as surely as an older
  one, because a platform cannot know what a protocol from after it expects.
  """
  @spec compatible?(term()) :: boolean()
  def compatible?(protocol) when is_integer(protocol),
    do: protocol >= @minimum and protocol <= @current

  def compatible?(_protocol), do: false

  @doc """
  Whether `protocol` is one a platform can write down at all, compatible or not: a whole number
  from 0 to the largest a Postgres `integer` holds. What a worker sends or a snapshot label says
  is recorded before it is judged, and a value the column would reject crashed the join it came
  in on rather than being refused by it.
  """
  @spec recordable?(term()) :: boolean()
  def recordable?(protocol) when is_integer(protocol),
    do: protocol >= 0 and protocol <= 2_147_483_647

  def recordable?(_protocol), do: false

  @doc "The accepted range as the product says it: `minimum–current`."
  @spec range() :: String.t()
  def range, do: "#{@minimum}–#{@current}"
end
