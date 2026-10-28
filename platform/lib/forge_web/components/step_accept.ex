defmodule ForgeWeb.Components.StepAccept do
  @moduledoc """
  The Accept area of a chat step (`docs/design/ui.md` § The Accept area): the documents the step
  declares with their latest versions, the outcome the person picks when there is a choice, and a
  deliberate second step before the ticket moves on.

  One component for the conversation's page and the ticket's Decide tab, drawn from
  `Forge.Steps.view/2`. Every name that reaches it — a document, an outcome, a state — is text a
  workflow author or an agent chose, so it is drawn escaped (never as markup) and, where it sits
  in a line, cut with `truncate` rather than allowed to widen the page.
  """

  use Phoenix.Component

  attr :step, :map, required: true, doc: "`Forge.Steps.view/2`"
  attr :pick, :string, default: nil
  attr :confirming, :boolean, default: false
  attr :error, :string, default: nil

  def accept_area(assigns) do
    pick = effective_pick(assigns.step, assigns.pick)

    assigns =
      assign(assigns,
        picked: pick,
        choice: choice?(assigns.step),
        wrap: "min-w-0 [overflow-wrap:anywhere]"
      )

    ~H"""
    <section
      id="step-accept"
      aria-label="Accept this step"
      class="flex min-w-0 flex-col gap-2 rounded-box border border-base-300 p-3"
    >
      <h3 class="min-w-0 truncate text-sm font-medium">
        Accept step <span class="font-mono text-[12.5px]">{@step.state}</span>
      </h3>

      <p :if={@error} id="step-error" role="alert" class={["text-sm text-error", @wrap]}>{@error}</p>

      <p :if={@step.over} id="step-over" class={["text-sm opacity-70", @wrap]}>
        {over_words(@step.over)}
      </p>

      <ul :if={@step.over == nil} id="step-documents" class="flex flex-col gap-1">
        <li :for={doc <- @step.documents} class="flex min-w-0 items-baseline gap-2 text-sm">
          <span class="min-w-0 truncate font-mono text-[12.5px]">{doc.name}</span>
          <span class="shrink-0 opacity-70">{document_words(doc)}</span>
        </li>
        <li :if={@step.documents == []} class="text-sm opacity-70">
          This step declares no document.
        </li>
      </ul>

      <p
        :if={@step.over == nil and nothing_yet?(@step)}
        id="step-nothing-yet"
        class={["text-sm opacity-70", @wrap]}
      >
        Expected: {Enum.map_join(own(@step), ", ", & &1.name)}. They appear here as the agent
        writes them.
      </p>

      <div :if={blocked_all?(@step)} id="step-blocked" class="flex min-w-0 flex-col gap-1 text-sm">
        <p class="opacity-70">No way out of this step can be taken now.</p>
        <ul class="flex flex-col gap-1">
          <li :for={outcome <- @step.outcomes} class="flex min-w-0 items-baseline gap-2">
            <span class="min-w-0 truncate font-mono text-[12.5px]">{outcome.outcome}</span>
            <span class={["opacity-70", @wrap]}>{outcome_words(outcome)}</span>
          </li>
        </ul>
      </div>

      <p :if={@step.over == nil and @step.in_flight} id="step-waiting" class="text-sm opacity-70">
        Waiting for the reply to finish.
      </p>

      <p
        :if={
          @step.over == nil and not @step.in_flight and @step.missing != [] and
            not nothing_yet?(@step)
        }
        id="step-missing"
        class={["text-sm opacity-70", @wrap]}
      >
        Not written yet: {Enum.join(@step.missing, ", ")}. Ask the agent for it.
      </p>

      <p :if={@step.over == nil and @step.dormant} id="step-dormant" class="text-sm opacity-70">
        The conversation has stopped. You can still accept what it wrote, or reopen it to go on.
      </p>

      <form
        :if={@step.over == nil and @step.ready}
        id="step-accept-form"
        phx-change="step:pick"
        phx-submit="step:accept"
        class="flex min-w-0 flex-col gap-2"
      >
        <input type="hidden" name="confirming" value={to_string(@confirming)} />
        <%!-- What the person was shown, sent back as it was drawn: Accept refuses if a newer
              version has been written since, and never approves one nobody saw. --%>
        <input
          :for={doc <- @step.documents}
          type="hidden"
          name={"seen[#{doc.name}]"}
          value={doc.version}
        />

        <fieldset :if={@choice} class="flex min-w-0 flex-col gap-2">
          <legend class="text-sm opacity-70">Where to next</legend>
          <label
            :for={outcome <- @step.outcomes}
            class={[
              "flex min-h-[46px] min-w-0 items-center gap-3 rounded-field border border-base-300 px-3 py-1",
              outcome.blocked && "opacity-50"
            ]}
          >
            <input
              type="radio"
              name="outcome"
              value={outcome.outcome}
              checked={@picked == outcome.outcome}
              disabled={outcome.blocked != nil}
            />
            <span class="min-w-0 flex-1 text-sm">
              <span class="block truncate font-mono text-[12.5px]">{outcome.outcome}</span>
              <span class="block truncate opacity-70">{outcome_words(outcome)}</span>
            </span>
          </label>
        </fieldset>
        <input :if={not @choice} type="hidden" name="outcome" value={@picked} />

        <button
          :if={not @confirming}
          type="button"
          phx-click="step:review"
          disabled={@picked == nil}
          class="min-h-[46px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100 disabled:opacity-40"
        >
          Review, then accept
        </button>

        <div :if={@confirming and @picked} id="step-confirm" class="flex flex-col gap-2">
          <p class={["text-sm", @wrap]}>
            {summary(@step, @picked)}
          </p>
          <div class="flex gap-2">
            <button
              type="submit"
              phx-disable-with="Accepting…"
              class="min-h-[46px] min-w-0 flex-1 rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
            >
              Accept
            </button>
            <button
              type="button"
              phx-click="step:cancel"
              class="min-h-[46px] rounded-field border border-base-300 px-4 text-sm"
            >
              Not yet
            </button>
          </div>
        </div>
      </form>
    </section>
    """
  end

  # A step with one way out picks it; several leave nothing preselected, and a pick that is no
  # longer an outcome with an edge left is dropped rather than carried into a refusal.
  defp effective_pick(%{outcomes: outcomes}, pick) do
    open = for %{outcome: name, blocked: nil} <- outcomes, do: name

    cond do
      pick in open -> pick
      length(outcomes) == 1 and length(open) == 1 -> hd(open)
      true -> nil
    end
  end

  # Every outcome refused and nothing else the page says explains it: the documents are written and
  # no reply is in flight, so without this the area lists documents and offers nothing, and no
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

  defp summary(%{outcomes: outcomes}, picked) do
    outcome = Enum.find(outcomes, &(&1.outcome == picked))

    case outcome do
      %{to: to, approve: []} ->
        "Accepting moves the ticket to #{to} and starts what comes next there."

      %{to: to, approve: names} ->
        "Accepting approves the latest version of #{Enum.join(names, ", ")} and moves the ticket to #{to}."
    end
  end

  defp over_words(:accepted), do: "This step was accepted."
  defp over_words(:moved), do: "The ticket has moved on from this step."

  defp over_words(:superseded),
    do: "The ticket came back to this step; its newer conversation is the one to use."

  defp over_words(:not_open), do: "The ticket is not open, so the step cannot be accepted."
end
