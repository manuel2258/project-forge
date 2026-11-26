defmodule ForgeWeb.Components.MoreRoom do
  @moduledoc """
  The fields under the *Extend* and *Run again* rows of a stuck ticket's ways forward
  (`docs/design/ui.md` § Steps): on the ticket page and on the queue's stuck item alike, so the two
  never offer different ways on.

  **One read model, `view/4`, and one component, `fields/1`.** The model is pure: what the boxes
  hold — what the person typed, else the half of the state's budget they start at — and whether the
  *raise this ticket's cap by* box is drawn, which is decided here and nowhere else: only when what
  would be spent (the tokens typed on Extend, the state's budget on Run again) exceeds what the
  ticket has left. It is filled with the shortfall until the person types in it.

  Figures are in the grammar the boxes take (`800k`, `1.5M`, `2000000`) so that what a facts line
  says and what is typed are the same units, with the exact weighted tokens in a title
  (`ForgeWeb.Format.exact/1`). A note is text: shown as typed, line breaks kept, and wrapped.

  The time box is drawn on every extension, for both harnesses, in the grammar a workflow writes a
  `timeout` in (`90s`, `20m`, `3h`), and starts filled with the limit each run of the job has.

  The fields carry a hidden `draft` naming the form's held draft (`ForgeWeb.Operator.Drafts`), so
  that a rejoin gives back what was typed, and a hidden `job` naming the job the person was shown,
  which is the one the act checks and acts on.
  """

  use Phoenix.Component

  import ForgeWeb.CoreComponents, only: [input: 1]

  alias ForgeCore.Usage

  @type model :: %{
          way: String.t(),
          tokens: String.t(),
          turns: String.t(),
          timeout: String.t(),
          note: String.t(),
          raise?: boolean(),
          raise: String.t(),
          shortfall: non_neg_integer(),
          left: non_neg_integer(),
          cap: non_neg_integer(),
          new_cap: non_neg_integer(),
          lowered?: boolean(),
          need: non_neg_integer() | nil
        }

  @doc """
  What the fields of `way` (`"extend"` or `"again"`) hold and show, from the `offer`
  (`Forge.Jobs.Extensions.offer/1`, nil on *Run again* alone), the ticket's `room`
  (`Forge.Jobs.Extensions.cap_facts/2`) and the held `draft` of the form — a map of what was typed.
  """
  @spec view(String.t(), map() | nil, map(), map()) :: model()
  def view(way, offer, room, draft) do
    tokens = Map.get(draft, "tokens") || default_tokens(offer)
    need = need(way, tokens, room)

    %{
      way: way,
      tokens: tokens,
      turns: Map.get(draft, "turns") || default_turns(offer),
      timeout: Map.get(draft, "timeout") || default_timeout(offer),
      note: Map.get(draft, "note") || "",
      need: need
    }
    |> Map.merge(raise_view(way, need, room, Map.get(draft, "raise")))
  end

  # The cap raise: drawn only when what would be spent exceeds what is left, filled with the
  # shortfall until the person types in it (`typed`, even when emptied), and saying the cap's old
  # and new figures. On a run again with something left, emptying it says the run is lowered.
  defp raise_view(way, need, room, typed) do
    shortfall = if need && need > room.left, do: need - room.left, else: 0
    text = typed || if(shortfall > 0, do: Usage.format(shortfall), else: "")
    raised = parsed(text)

    %{
      raise?: shortfall > 0,
      raise: text,
      shortfall: shortfall,
      left: room.left,
      cap: room.cap,
      new_cap: room.cap + (raised || shortfall),
      lowered?: way == "again" and shortfall > 0 and room.left > 0 and raised == nil
    }
  end

  defp default_tokens(%{default_tokens: tokens}), do: Usage.format(tokens)
  defp default_tokens(_no_offer), do: ""

  defp default_turns(%{default_turns: turns}), do: Integer.to_string(turns)
  defp default_turns(_no_offer), do: ""

  # The state's own limit and not half of it, as the other two boxes start: the limit is per run,
  # and an extended run is a new one (`docs/design/ui.md` § Extend).
  defp default_timeout(%{timeout_ms: ms}), do: ForgeCore.Duration.format(ms)
  defp default_timeout(_no_offer), do: ""

  # What the act would spend, which is what the cap is judged against: the tokens typed, or the
  # state's own budget. Nil while what was typed is not an amount, so no raise is drawn for it and
  # the act refuses it in words.
  defp need("extend", tokens, _room), do: parsed(tokens)
  defp need("again", _tokens, room), do: room.restart_need

  # A zero is not an amount: typed as the raise it is none, which the act reads the same way and
  # runs lowered (`Extensions.parse_restart/1`), so the form must not draw a new cap for it.
  defp parsed(text) do
    case Usage.parse(text) do
      {:ok, amount} when amount > 0 -> amount
      _not_an_amount -> nil
    end
  end

  attr :way, :string, required: true, values: ~w(extend again)
  attr :offer, :map, default: nil, doc: "`Forge.Jobs.Extensions.offer/1`; required for `extend`"
  attr :room, :map, required: true, doc: "`Forge.Jobs.Extensions.cap_facts/2`"
  attr :drafts, :map, required: true
  attr :draft, :string, required: true, doc: "the form's key in `drafts`"
  attr :prefix, :string, required: true, doc: "makes the ids unique where several are drawn"
  attr :project, :string, default: nil, doc: "the project's name: with it, files can be attached"

  attr :form, :string,
    default: nil,
    doc: "the id of the form the fields belong to, when outside it"

  @doc "The fields: the facts, the boxes, the note and, only when it matters, the cap raise."
  def fields(assigns) do
    model =
      view(assigns.way, assigns.offer, assigns.room, Map.get(assigns.drafts, assigns.draft, %{}))

    assigns = assign(assigns, :m, model)

    ~H"""
    <div id={"#{@prefix}-#{@way}-fields"} class="ui-room">
      <input type="hidden" name="draft" value={@draft} form={@form} />
      <input :if={@way == "extend"} type="hidden" name="job" value={@offer.job_id} form={@form} />

      <%= if @way == "extend" do %>
        <p id={"#{@prefix}-extend-facts"} class="ui-room-facts">
          {ran_out(@offer)}
          <span title={ForgeWeb.Format.exact(@offer.used_tokens)}>
            It has used {Usage.format(@offer.used_tokens)} weighted tokens
          </span>
          and {@offer.used_turns} turns over {@offer.runs} {if @offer.runs == 1,
            do: "run",
            else: "runs"}; the
          state declares
          <span title={ForgeWeb.Format.exact(@offer.declared_tokens)}>
            {Usage.format(@offer.declared_tokens)}
          </span>
          and {@offer.declared_turns} turns, and each run may take {ForgeCore.Duration.format(
            @offer.timeout_ms
          )}.
          <span title={ForgeWeb.Format.exact(@room.left)}>
            The ticket has {Usage.format(@room.left)} of {Usage.format(@room.cap)} left.
          </span>
        </p>
        <p class="ui-room-facts">
          This is what the reopened run may spend <strong>on top of</strong>
          what the job has already spent. It is never a new total, and nothing here lowers anything.
        </p>
        <.input
          id={"#{@prefix}-extend-tokens"}
          name="tokens"
          label="Tokens to add"
          value={@m.tokens}
          mono
          form={@form}
          autocomplete="off"
          inputmode="text"
          phx-debounce="300"
          hint="Such as 800k, 1.5M or 2000000."
        />
        <.input
          id={"#{@prefix}-extend-timeout"}
          name="timeout"
          label="Time for this run"
          value={@m.timeout}
          mono
          form={@form}
          autocomplete="off"
          inputmode="text"
          phx-debounce="300"
          hint="Such as 90s, 20m or 3h."
        />
        <.input
          :if={@offer.bounds_turns}
          id={"#{@prefix}-extend-turns"}
          name="turns"
          label="Turns to add"
          value={@m.turns}
          mono
          form={@form}
          autocomplete="off"
          inputmode="numeric"
          phx-debounce="300"
        />
      <% else %>
        <p id={"#{@prefix}-again-facts"} class="ui-room-facts">
          A new job from scratch on the state's own budget{budget_phrase(@m.need)}. The ticket has
          <span title={ForgeWeb.Format.exact(@room.left)}>
            {Usage.format(@room.left)} of {Usage.format(@room.cap)}
          </span>
          left.
        </p>
      <% end %>

      <ForgeWeb.UI.Attach.field id={"#{@prefix}-#{@way}-attach"} project={@project} form={@form}>
        <.input
          id={"#{@prefix}-#{@way}-note"}
          name="note"
          label="Note, for the agent (optional)"
          value={@m.note}
          multiline
          rows="3"
          form={@form}
          phx-debounce="300"
          maxlength={4000}
          class="[overflow-wrap:anywhere] whitespace-pre-wrap"
          hint={note_hint(@way)}
        >
          <:lead :if={@project}><ForgeWeb.UI.Attach.clip /></:lead>
        </.input>
      </ForgeWeb.UI.Attach.field>

      <div :if={@m.raise?} id={"#{@prefix}-#{@way}-raise"} class="ui-room-raise">
        <.input
          id={"#{@prefix}-#{@way}-raise-box"}
          name="raise"
          label="Raise this ticket's cap by"
          value={@m.raise}
          mono
          form={@form}
          autocomplete="off"
          inputmode="text"
          phx-debounce="300"
        />
        <p class="ui-room-facts" id={"#{@prefix}-#{@way}-raise-says"}>
          <%= if @m.lowered? do %>
            Left empty, the run is lowered to what the ticket has left, <span title={
              ForgeWeb.Format.exact(@m.left)
            }>{Usage.format(@m.left)}</span>.
          <% else %>
            The cap goes from
            <span title={ForgeWeb.Format.exact(@m.cap)}>{Usage.format(@m.cap)}</span>
            to <span title={ForgeWeb.Format.exact(@m.new_cap)}>{Usage.format(@m.new_cap)}</span>
            for the rest of this ticket's life.
          <% end %>
        </p>
      </div>
    </div>
    """
  end

  defp budget_phrase(0), do: ""
  defp budget_phrase(tokens), do: " (#{Usage.format(tokens)})"

  defp ran_out(%{exhausted: :turns}), do: "It ran out of turns."
  defp ran_out(%{exhausted: :tokens}), do: "It ran out of tokens."
  defp ran_out(%{exhausted: :timeout}), do: "It reached its timeout."
  defp ran_out(_offer), do: "It ran out of budget."

  defp note_hint("extend"), do: "The first thing the job reads when it carries on."
  defp note_hint("again"), do: "Shown to the new attempt as how it came to be here."
end
