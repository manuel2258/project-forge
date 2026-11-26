defmodule ForgeCore.Workflow.Command do
  @moduledoc """
  One command a workflow declares under `commands:`: a fixed script that a command state runs on
  entry and an agent may invoke mid-job. `docs/design/commands.md` is the mechanism and
  `docs/design/workflow-grammar-v1.md` § Commands the grammar.

  `run` is a path relative to the repository root, read at the ticket's pinned commit — never the
  branch a job is editing, so an agent cannot change what the command it is judged by does.
  `produces` names the artifact the command's combined output is recorded as, if any, and
  `outputs` the groups of files its script writes (`produces: [build.log, package/*]` in the
  workflow).
  """

  alias ForgeCore.Workflow.Resources

  @enforce_keys [:name]
  defstruct [
    :name,
    :run,
    :env,
    :produces,
    :timeout_ms,
    :resources,
    outputs: [],
    secrets: [],
    keep_build: [],
    warm_start: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          run: String.t() | nil,
          env: String.t() | nil,
          produces: String.t() | nil,
          # Groups of files the script writes into `$FORGE_OUT/<group>/`, as `package/*`.
          outputs: [String.t()],
          timeout_ms: pos_integer() | nil,
          resources: Resources.t() | nil,
          # The project secrets the command's job is handed, by name, whoever invokes it
          # (`docs/design/secrets.md` § The workflow is the access list).
          secrets: [String.t()],
          # The exit statuses whose tree the ticket's next command starts from (`docs/design/
          # worker-tier.md` § The command copy). Empty keeps nothing, which is every command
          # written before it existed.
          keep_build: [0..255],
          # Whether the command starts from the ticket's command copy when it has one.
          warm_start: boolean()
        }

  @doc """
  An argument vector as it is shown — the prompt, the timeline, a command's page, an event's
  summary: JSON, so `foo bar` is visibly one argument and `$HOME` visibly text.
  """
  @spec argv([String.t()] | nil) :: String.t()
  def argv(args), do: Jason.encode!(args || [])

  @max_ms :timer.hours(24)

  @doc """
  Parses a duration: a whole number and one unit — `90s`, `20m`, `2h` — or a bare positive integer
  of seconds, in milliseconds (`ForgeCore.Duration`, which an agent state's `timeout` reads too).

  **At most a day.** The worker arms a timer with it, and a number past the runtime's largest
  timer does not wait for ever: it crashes the command on the machine. A day is far inside that,
  and a build that needs longer is not one a ticket should wait on.
  """
  @spec parse_duration(term()) :: {:ok, pos_integer()} | :error
  def parse_duration(value) do
    case ForgeCore.Duration.parse(value, @max_ms) do
      {:ok, ms} -> {:ok, ms}
      _ -> :error
    end
  end
end
