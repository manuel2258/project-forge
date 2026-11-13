defmodule ForgeWeb.Components.StepAccept do
  @moduledoc """
  The Accept area of a chat step (`docs/design/ui.md` § The Accept area), in two parts drawn from
  one read model, `Forge.Steps.view/2`, on the conversation's page and on the ticket's:

    * `status/1`, in place — what the step says while there is nothing to accept yet, or no
      longer anything: nothing written, a reply in flight before the first version, the step
      over;
    * `panel/1`, the body of Accept's drop panel under the decision row
      (`ForgeWeb.Operator.Decision`) — the documents with their versions, the outcome when there
      is a choice, what blocks it, and the hidden fields that say what the person was shown.

  Every name that reaches it — a document, an outcome, a state — is text a workflow author or an
  agent chose, so it is drawn escaped (never as markup) and, where it sits in a line, cut with
  `truncate` rather than allowed to widen the page.
  """

  use Phoenix.Component

  import ForgeWeb.UI.Forms, only: [choice_row: 1]

  @doc """
  Whether the step has a decision to show as a row: it is current and something it must produce
  has a version, or it must produce nothing (`16e` → `16f`). A reply in flight keeps the row with
  its button disabled; it does not take the row away.
  """
  @spec row?(map() | nil) :: boolean()
  def row?(%{over: nil} = step), do: not nothing_yet?(step)
  def row?(_step), do: false

  attr :step, :map, required: true, doc: "`Forge.Steps.view/2`"

  @doc "What the step says in place while it has no row: nothing yet, or over."
  def status(assigns) do
    assigns = assign(assigns, wrap: "min-w-0 [overflow-wrap:anywhere]")

    ~H"""
    <section
      :if={not row?(@step)}
      id="step-status"
      aria-label="Accepting this step"
      class="flex min-w-0 flex-col gap-1 text-sm text-ink-2"
    >
      <p :if={@step.over} id="step-over" class={@wrap}>{over_words(@step.over)}</p>
      <p :if={@step.over == nil} id="step-nothing-yet" class={@wrap}>
        Nothing to accept yet. Expected: {Enum.map_join(own(@step), ", ", & &1.name)}. They appear
        as the agent writes them.
      </p>
      <p :if={@step.over == nil and @step.in_flight} id="step-waiting">
        Waiting for the reply to finish.
      </p>
      <p :if={@step.over == nil and @step.dormant} id="step-dormant" class={@wrap}>
        The conversation has stopped. Reopen it to go on.
      </p>
    </section>
    """
  end

  attr :step, :map, required: true
  attr :pick, :string, default: nil

  @doc """
  The Accept panel's body: inside the decision panel's form, so the outcome picked rides in the
  form's `phx-change` and comes back on a rejoin, and the version of each document as it was drawn
  rides in hidden fields — what Accept is told it was shown, so it never approves a version nobody
  saw (`ForgeWeb.Operator.Decision`).
  """
  def panel(assigns) do
    assigns =
      assign(assigns,
        picked: effective_pick(assigns.step, assigns.pick),
        choice: choice?(assigns.step),
        wrap: "min-w-0 [overflow-wrap:anywhere]"
      )

    ~H"""
    <ul id="step-documents" class="flex flex-col gap-1">
      <li :for={doc <- @step.documents} class="flex min-w-0 items-baseline gap-2 text-sm">
        <span class="min-w-0 truncate font-mono text-[12.5px]">{doc.name}</span>
        <span class="shrink-0 text-ink-2">{document_words(doc)}</span>
      </li>
      <li :if={@step.documents == []} class="text-sm text-ink-2">
        This step declares no document.
      </li>
    </ul>

    <p :if={@step.in_flight} id="step-waiting" class="text-sm text-ink-2">
      Waiting for the reply to finish.
    </p>

    <p
      :if={not @step.in_flight and @step.missing != []}
      id="step-missing"
      class={["text-sm text-ink-2", @wrap]}
    >
      Not written yet: {Enum.join(@step.missing, ", ")}. Ask the agent for it.
    </p>

    <p :if={@step.dormant} id="step-dormant" class={["text-sm text-ink-2", @wrap]}>
      The conversation has stopped. You can still accept what it wrote, or reopen it to go on.
    </p>

    <div :if={blocked_all?(@step)} id="step-blocked" class="flex min-w-0 flex-col gap-1 text-sm">
      <p class="text-ink-2">No way out of this step can be taken now.</p>
      <ul class="flex flex-col gap-1">
        <li :for={outcome <- @step.outcomes} class="flex min-w-0 items-baseline gap-2">
          <span class="min-w-0 truncate font-mono text-[12.5px]">{outcome.outcome}</span>
          <span class={["text-ink-2", @wrap]}>{outcome_words(outcome)}</span>
        </li>
      </ul>
    </div>

    <%!-- What the person was shown, sent back as it was drawn: Accept refuses if a newer version
          has been written since, and never approves one nobody saw. --%>
    <input
      :for={doc <- @step.documents}
      type="hidden"
      name={"seen[#{doc.name}]"}
      value={doc.version}
    />

    <%!-- None preselected (`ui.md` § The Accept area): the outcome decides where the ticket goes,
          and a default would be that decision taken for the person. --%>
    <fieldset
      :if={@step.ready and @choice}
      id="step-outcomes"
      class="flex min-w-0 flex-col gap-2"
    >
      <legend class="mb-1 font-mono text-[11px] tracking-[.14em] uppercase text-ink-3">
        outcome
      </legend>
      <.choice_row
        :for={outcome <- @step.outcomes}
        id={"step-outcome-#{outcome.outcome}"}
        name="outcome"
        value={outcome.outcome}
        label={outcome.outcome}
        detail={outcome_words(outcome)}
        selected={@picked == outcome.outcome}
        disabled={outcome.blocked != nil}
      />
    </fieldset>
    <input :if={@step.ready and not @choice} type="hidden" name="outcome" value={@picked} />
    """
  end

  @doc """
  The outcome Accept would take: the one picked, when it is still open; the only one, for a step
  with one way out; otherwise none. A pick that is no longer an outcome with an edge left is
  dropped rather than carried into a refusal.
  """
  @spec effective_pick(map(), String.t() | nil) :: String.t() | nil
  def effective_pick(%{outcomes: outcomes}, pick) do
    open = for %{outcome: name, blocked: nil} <- outcomes, do: name

    cond do
      pick in open -> pick
      length(outcomes) == 1 and length(open) == 1 -> hd(open)
      true -> nil
    end
  end

  @doc "What accepting with `picked` does, in a sentence; a prompt to pick when nothing is."
  @spec summary(map(), String.t() | nil) :: String.t()
  def summary(%{outcomes: outcomes}, picked) do
    case Enum.find(outcomes, &(&1.outcome == picked)) do
      %{to: to, approve: []} ->
        "Ends the chat step and moves the ticket to #{to}."

      %{to: to, approve: names} ->
        "Ends the chat step, approves the latest version of #{Enum.join(names, ", ")} and " <>
          "moves the ticket to #{to}."

      nil ->
        "Ends the chat step. Pick where the ticket goes next."
    end
  end

  @doc "Where accepting with `picked` takes the ticket, or nil while nothing is picked."
  @spec target(map(), String.t() | nil) :: String.t() | nil
  def target(%{outcomes: outcomes}, picked) do
    case Enum.find(outcomes, &(&1.outcome == picked)) do
      %{to: to} -> to
      nil -> nil
    end
  end

  # Every outcome refused and nothing else the panel says explains it: the documents are written
  # and no reply is in flight, so without this it lists documents and offers nothing, and no
  # reason.
  defp blocked_all?(%{over: nil, in_flight: false, missing: [], outcomes: outcomes}),
    do: Enum.all?(outcomes, &(&1.blocked != nil))

  defp blocked_all?(_step), do: false

  defp choice?(%{outcomes: outcomes}), do: length(outcomes) > 1

  defp own(%{documents: docs}), do: Enum.filter(docs, & &1.own)

  defp nothing_yet?(step) do
    own = own(step)
    own != [] and Enum.all?(own, &(&1.version == nil))
  end

  defp document_words(%{version: nil, optional: true}), do: "optional, not written"

  defp document_words(%{version: nil, own: false}),
    do: "not written yet, and an outcome approves it"

  defp document_words(%{version: nil}), do: "not written yet"
  defp document_words(%{version: v, this_visit: true}), do: "version #{v}, written in this visit"
  defp document_words(%{version: v, own: false}), do: "version #{v}, from an earlier step"
  defp document_words(%{version: v}), do: "version #{v}, from an earlier visit"

  defp outcome_words(%{blocked: :no_edge}), do: "no way on from here"

  defp outcome_words(%{blocked: :no_version, unwritten: names}),
    do:
      "approves #{Enum.join(names, ", ")}, which nobody has written yet. Ask the agent to write it"

  defp outcome_words(%{blocked: :max_spent}), do: "already taken as often as allowed"
  defp outcome_words(%{to: to, approve: []}), do: "goes to #{to}"

  defp outcome_words(%{to: to, approve: names}),
    do: "goes to #{to}, approving #{Enum.join(names, ", ")}"

  defp over_words(:accepted), do: "This step was accepted."
  defp over_words(:moved), do: "The ticket has moved on from this step."

  defp over_words(:superseded),
    do: "The ticket came back to this step; its newer conversation is the one to use."

  defp over_words(:not_open), do: "The ticket is not open, so the step cannot be accepted."
end
