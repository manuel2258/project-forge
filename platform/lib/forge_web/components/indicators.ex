defmodule ForgeWeb.Indicators do
  @moduledoc """
  The three axes, given three different forms rather than three colours of one badge.

  Form survives greyscale, colour blindness and a glance; colour alone does not. See
  `docs/design/ui.md` — these components are the rule, and nothing else may draw a workflow
  state, a ticket status or a job outcome.

    * `state/1` — plain mono with a leading topology glyph. No border: an identifier is never
      tappable, and in this system a border means you can tap it.
    * `status_flag/1` — a filled uppercase flag beside the state, rendered only when the status
      is not `active`. It never replaces the state.
    * `outcome/1` — bare coloured mono at type scale. The declared outcome is the loud one; the
      engine outcome is demoted beside it.
  """
  use ForgeWeb, :html

  @doc """
  A workflow state: mono text with its topology glyph.

  `▸` runs a job on entry, `●` waits for a person, `■` is terminal. The glyph is a text
  character so it inherits colour and size from the identifier it belongs to. Never coloured by
  status, never abbreviated.
  """
  attr :name, :string, required: true
  attr :topology, :atom, required: true, values: [:job, :human, :terminal, :unknown]
  attr :class, :string, default: nil

  def state(assigns) do
    ~H"""
    <span class={["font-mono text-[12.5px] whitespace-nowrap", @class]}>
      <span class={[
        @topology == :job && "text-info",
        @topology == :human && "text-primary",
        @topology in [:terminal, :unknown] && "opacity-50"
      ]}>{glyph(@topology)}</span>
      {@name}
    </span>
    """
  end

  defp glyph(:job), do: "▸"
  defp glyph(:human), do: "●"
  defp glyph(:terminal), do: "■"
  defp glyph(:unknown), do: "·"

  @doc """
  A ticket status, as a filled uppercase flag.

  Rendered only when the status is not `active` — an active ticket says nothing, because its
  state already does. `stuck` carries its age and is the one status drawn in accent, since a
  stuck ticket is waiting on a human.
  """
  attr :status, :atom, required: true
  attr :age, :string, default: nil, doc: "relative age, shown inside the stuck flag"

  def status_flag(assigns) do
    ~H"""
    <span
      :if={@status != :active}
      class={[
        "font-mono text-[11px] tracking-[.14em] uppercase px-1.5 py-0.5 whitespace-nowrap",
        @status == :stuck && "bg-accent text-accent-content",
        @status == :done && "border border-success text-success",
        @status == :cancelled && "bg-base-300 text-base-content/70"
      ]}
    >
      {@status}{if @status == :stuck and @age, do: " #{@age}"}
    </span>
    """
  end

  @doc """
  A job outcome as bare coloured mono.

  Colour maps by bucket, never by string match: declared outcomes are project-defined, so an
  unrecognised value is drawn neutral rather than guessed at. `did_not_converge` is deliberately
  not an error — it is the agent honestly reporting it could not finish.
  """
  attr :value, :string, required: true
  attr :bucket, :atom, default: nil, doc: "overrides the inferred bucket"
  attr :class, :string, default: "text-[12.5px]"

  def outcome(assigns) do
    assigns = assign_new(assigns, :resolved, fn -> assigns.bucket || bucket(assigns.value) end)

    ~H"""
    <span class={[
      "font-mono whitespace-nowrap",
      @class,
      @resolved == :success && "text-success",
      @resolved == :non_completion && "text-warning",
      @resolved == :failure && "text-error",
      @resolved == :neutral && "opacity-70"
    ]}>
      {@value}
    </span>
    """
  end

  @doc """
  The bucket an engine outcome falls in. Anything unrecognised is neutral, never a guess.
  """
  @spec bucket(String.t() | atom() | nil) :: :success | :non_completion | :failure | :neutral
  def bucket(nil), do: :neutral
  def bucket(value) when is_atom(value), do: value |> Atom.to_string() |> bucket()
  def bucket("converged"), do: :success
  def bucket("did_not_converge"), do: :non_completion
  def bucket("budget_exhausted"), do: :non_completion
  def bucket("error"), do: :failure
  def bucket("cancelled"), do: :neutral
  def bucket(_other), do: :neutral

  @doc """
  A job status. Plain mono, never boxed — nothing on any axis is boxed.
  """
  attr :status, :atom, required: true

  def job_status(assigns) do
    ~H"""
    <span class={[
      "font-mono text-[12.5px]",
      @status == :running && "text-info",
      @status == :waiting && "text-accent",
      @status not in [:running, :waiting] && "opacity-70"
    ]}>
      {@status}
    </span>
    """
  end
end
