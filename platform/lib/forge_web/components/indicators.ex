defmodule ForgeWeb.Indicators do
  @moduledoc """
  The three axes, given three different forms rather than three colours of one badge.

  Form survives greyscale, colour blindness and a glance; colour alone does not. See
  `docs/design/ui.md` — these components are the rule, and nothing else may draw a workflow
  state, a ticket status or a job outcome.

    * `state/1` — plain mono with a leading topology glyph. No border: an identifier is never
      tappable, and in this system a border means you can tap it.
    * `outcome/1` — bare coloured mono at type scale. The declared outcome is the loud one; the
      engine outcome is demoted beside it.
    * `ceiling/1` — what a `budget_exhausted` job ran out of, demoted beside its outcome. The
      outcome alone says a job ran out; only this says out of what.
  """
  use ForgeWeb, :html

  @doc """
  A workflow state: mono text led by its topology mark (`docs/design/ui.md` § The three axes), in
  StateLabel's classes (`ForgeWeb.UI.Data.state_label/1`).

  The mark is `ForgeWeb.Topology.mark/1`'s and nothing else's: `▸` runs a job on entry (info), `●`
  waits for a person (link), `○` is terminal and `·` unknown (both muted). A terminal state is
  never `✓` — names are the project's, and the platform cannot tell a `done` from an `abandoned` —
  and a state is never coloured by the ticket's status, which is a word beside it. The one colour
  that is not the topology's is `waiting`: a person is waited on in it, and its mark is amber.
  """
  attr :name, :string, required: true
  attr :topology, :atom, required: true, values: [:job, :human, :terminal, :unknown]
  attr :waiting, :boolean, default: false, doc: "a person is waited on in it: the mark is amber"

  def state(assigns) do
    assigns = assign(assigns, :tone, tone(assigns.topology, assigns.waiting))

    ~H"""
    <span class={["ui-state", "ui-state--#{@tone}"]}><span
      class="ui-state-mark"
      aria-hidden="true"
    >{ForgeWeb.Topology.mark(@topology)}</span> {@name}</span>
    """
  end

  @doc """
  A ticket's status, as a word beside its state and never instead of it (`docs/design/ui.md`
  § The three axes): nothing while `active`, `stuck` in amber (it waits on you), anything else — `done`,
  `cancelled` — muted.
  """
  attr :status, :atom, required: true

  def status(%{status: :active} = assigns), do: ~H""

  def status(assigns) do
    ~H"""
    <span class={["ui-status", @status == :stuck && "ui-status--stuck"]}>{@status}</span>
    """
  end

  defp tone(_topology, true), do: "waiting"
  defp tone(:job, false), do: "running"
  defp tone(:human, false), do: "step"
  defp tone(_terminal_or_unknown, false), do: "idle"

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
      @resolved == :failure && "text-danger",
      @resolved == :neutral && "opacity-70"
    ]}>
      {@value}
    </span>
    """
  end

  @doc """
  What a `budget_exhausted` job ran out of, demoted beside its outcome: `turns`, `tokens` or
  `wall clock`.

  Drawn nowhere else and for no other outcome, and nothing at all for a job whose ceiling was
  not recorded — a row from before the column, or from a worker too old to send it — because an
  absent fact is not one of the three (`docs/design/capacity.md` § Four exhaustions, three
  treatments). Bare mono at a lower opacity than any outcome `outcome/1` draws, rather than a
  second badge: it qualifies the outcome, and two marks of equal weight would read as two
  outcomes. Every row that draws it draws its outcome through `outcome/1`, which is what keeps
  that true.
  """
  attr :job, :map, required: true

  def ceiling(assigns) do
    assigns = assign(assigns, :word, ceiling_word(assigns.job))

    ~H"""
    <span
      :if={@word}
      data-ceiling={@word}
      class="font-mono text-[12.5px] whitespace-nowrap opacity-50"
    >
      · {@word}
    </span>
    """
  end

  # The `outcome:` half of each pattern is an **equivalent mutant**: `Job.progress_changeset/2`
  # refuses `exhausted` on any outcome but `:budget_exhausted`, and the one write of `outcome`
  # that bypasses it is scoped to jobs that carry no ceiling — so a job with a ceiling and
  # another outcome is not a row this can be handed. Dropping it changes nothing observable, and
  # a test of it would have to build a row the platform cannot store. It is kept for what it
  # says: the ceiling belongs to that outcome and no other.
  defp ceiling_word(%{outcome: :budget_exhausted, exhausted: :turns}), do: "turns"
  defp ceiling_word(%{outcome: :budget_exhausted, exhausted: :tokens}), do: "tokens"
  defp ceiling_word(%{outcome: :budget_exhausted, exhausted: :wall_clock}), do: "wall clock"
  defp ceiling_word(_job), do: nil

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
  A command's result where a job's outcome goes (`docs/design/ui.md` § Decide and Timeline): its
  exit status — `exit 0` in success, any other in error — or, when it ended with none, the engine
  outcome that says why; its status while it has not ended. `class` sizes the first two, as
  `outcome/1`'s does: a command's page draws it as its headline.
  """
  attr :job, :map, required: true
  attr :class, :string, default: "text-[12.5px]"

  def exit_status(
        %{job: %{status: :finished, outcome: :converged, exit_status: status}} = assigns
      )
      when is_integer(status) do
    assigns = assign(assigns, value: "exit #{status}", ok: status == 0)

    ~H"""
    <.outcome value={@value} bucket={if @ok, do: :success, else: :failure} class={@class} />
    """
  end

  def exit_status(%{job: %{status: :finished, outcome: outcome}} = assigns) do
    assigns = assign(assigns, value: to_string(outcome))

    ~H"""
    <.outcome value={@value} class={@class} />
    """
  end

  def exit_status(assigns) do
    ~H"""
    <.job_status status={@job.status} />
    """
  end

  @doc """
  A job status. Plain mono, never boxed — nothing on any axis is boxed.
  """
  attr :status, :atom, required: true

  def job_status(assigns) do
    ~H"""
    <span class={
      [
        "font-mono text-[12.5px]",
        @status == :running && "text-info",
        @status == :waiting && "text-accent",
        # Waiting on its own commands, not on a person: no accent (`ui.md` § The three axes).
        @status == :parked && "text-info",
        @status not in [:running, :waiting, :parked] && "opacity-70"
      ]
    }>
      {@status}
    </span>
    """
  end
end
