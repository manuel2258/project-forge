defmodule ForgeWeb.UI.Decisions do
  @moduledoc """
  The decision primitives (`docs/design/ui/design_system/components/decisions/`,
  `docs/design/ui.md` § The decision row, § Drop panels): the row a decision lives in, pinned
  under the top bar, and the panel that drops from a bar.

  Styles are in `assets/css/components.css` under the same names.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  import ForgeWeb.CoreComponents, only: [button: 1]
  import ForgeWeb.UI.Data, only: [type_icon: 1]
  import ForgeWeb.UI.Feedback, only: [notice: 1]

  @doc """
  The only place a decision lives (`decisions/DecisionRow`): the object's kind, its name and key
  facts in mono, a meta line, and the button. **Amber** when it waits on you (Approve, Accept),
  leading with ◆; **neutral** outline when it does not (Merge a chat). A 2px inset edge in the
  button's colour. 60px with a 42px button on a phone; the frame draws it 56px with a 34px button
  from 768px (`assets/css/frame.css`, `docs/design/ui.md` § Space, sizes and targets).

  The button sends `on_toggle`; while `open` it reads `▴`, turns to the amber outline, and the
  inner block — the `drop_panel/1` — is drawn under the row.
  """
  attr :id, :string, default: nil
  attr :kind, :string, default: "changeset", values: ~w(doc changeset branch release)
  attr :action, :string, default: "Approve", doc: "the button's word; nil draws the row with none"
  attr :tone, :string, default: "accent", values: ~w(accent neutral)
  attr :open, :boolean, default: false
  attr :on_toggle, :any, default: nil, doc: "phx-click for the button"

  attr :patch, :string,
    default: nil,
    doc: "where the button goes instead of dropping a panel — it is then a link, with `›`"

  attr :disabled, :boolean,
    default: false,
    doc: "the button, while the decision exists but cannot be taken yet — a reply in flight"

  attr :rest, :global

  slot :title, required: true, doc: "the object and its key facts, e.g. changeset v1 +48 −6"
  slot :meta
  slot :inner_block, doc: "the drop panel, drawn while open"

  def decision_row(assigns) do
    ~H"""
    <div
      id={@id}
      class={["ui-decision", @tone == "neutral" && "ui-decision--neutral"]}
      {@rest}
    >
      <div class="ui-decision-bar">
        <.type_icon kind={@kind} />
        <div class="ui-decision-text">
          <span class="ui-decision-title">{render_slot(@title)}</span>
          <span :if={@meta != []} class="ui-decision-meta">{render_slot(@meta)}</span>
        </div>
        <.button
          :if={@action && is_nil(@patch)}
          type="button"
          size="md"
          variant={row_variant(@tone, @open)}
          phx-click={@on_toggle}
          aria-expanded={to_string(@open)}
          disabled={@disabled}
        >
          {@action}{if @open, do: " ▴"}
        </.button>
        <.button
          :if={@action && @patch}
          size="md"
          variant={row_variant(@tone, false)}
          patch={@patch}
          chevron
        >
          {@action}
        </.button>
      </div>
      {if @open, do: render_slot(@inner_block)}
    </div>
    """
  end

  defp row_variant("neutral", _open), do: "neutral"
  defp row_variant("accent", true), do: "decision-open"
  defp row_variant("accent", false), do: "decision"

  @doc """
  The one overlay pattern (`decisions/DropPanel`): it drops from the bar it belongs to — the title
  menu, an object's details, a decision's confirmation, usage — full width on a phone, over a
  scrim, and nothing underneath moves. Draw it inside a positioned bar (`top_bar/1`'s inner block,
  `decision_row/1`'s).

  A confirmation says what happens (`title`, `body`), warns of a consequence (`:warning`, a warning
  notice — "1 open question will stay unanswered"; questions are never answered in here), and ends
  with the secondary act and the primary, **the primary in the colour of the button that opened
  it**. `on_close` is sent by a tap on the scrim.
  """
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :body, :string, default: nil
  attr :secondary, :string, default: nil
  attr :secondary_variant, :string, default: "secondary", values: ~w(secondary danger quiet)
  attr :on_secondary, :any, default: nil
  attr :secondary_disabled, :boolean, default: false
  attr :primary, :string, default: nil
  attr :primary_variant, :string, default: "decision", values: ~w(decision primary neutral)
  attr :on_primary, :any, default: nil
  attr :primary_disabled, :boolean, default: false

  attr :form, :string,
    default: nil,
    doc: "a form id: the primary submits it rather than sending on_primary"

  attr :on_close, :any, default: nil
  attr :scrim, :boolean, default: true
  attr :rest, :global

  slot :warning do
    attr :title, :string, required: true
  end

  slot :inner_block

  def drop_panel(assigns) do
    ~H"""
    <div :if={@scrim} class="ui-drop-scrim" phx-click={@on_close} aria-hidden="true" />
    <div id={@id} class="ui-drop" {@rest}>
      <div :if={@title || @body} class="ui-drop-head">
        <span :if={@title} class="ui-drop-title">{@title}</span>
        <span :if={@body} class="ui-drop-body">{@body}</span>
      </div>
      <.notice :for={warning <- @warning} tone="warning" title={warning.title}>
        {render_slot(warning)}
      </.notice>
      {render_slot(@inner_block)}
      <div :if={@secondary || @primary} class="ui-drop-actions">
        <.button
          :if={@secondary}
          type="button"
          variant={@secondary_variant}
          size="lg"
          phx-click={@on_secondary}
          disabled={@secondary_disabled}
        >
          {@secondary}
        </.button>
        <.button
          :if={@primary}
          type={if @form, do: "submit", else: "button"}
          form={@form}
          variant={@primary_variant}
          size="lg"
          fill
          diamond={false}
          phx-click={!@form && @on_primary}
          disabled={@primary_disabled}
        >
          {@primary}
        </.button>
      </div>
    </div>
    """
  end

  @doc """
  An act that needs a second look, asked **in place** (`docs/design/ui.md` § The confirm): the
  trigger, and under it — once tapped — the sentence saying what will happen and two buttons named
  for the act, *Keep it* and `act` (*Revoke it*, *Destroy it*). Nothing else moves; the panel opens
  and folds in the browser, with no round trip, and stays open across the page's patches.

  This replaces the browser's own dialog behind `data-confirm`: *OK / Cancel*, unthemed, a
  system alert detached from the row it was about, and one that Chrome lets a person switch off
  for the rest of the page's life (UX pass, D3).

  The confirming button carries `id` and everything in `rest` — the `phx-click`, its values, its
  `phx-disable-with` — so it is the one that acts. `tone="danger"` (the default) draws a
  destructive act: the trigger outlined red, small, at the row's end in a list (`fill` on a page
  about one object only); the panel on the red wash with a red edge. `tone="neutral"` is an act
  that is weighty but destroys nothing — re-pinning, sending a ticket on.
  """
  attr :id, :string, required: true, doc: "the confirming button's; the trigger is `<id>-ask`"
  attr :label, :string, required: true, doc: "the trigger's words: the act, e.g. `Revoke`"
  attr :act, :string, required: true, doc: "the confirming button's words, e.g. `Revoke it`"
  attr :sentence, :string, required: true, doc: "what will happen, as a question or a statement"
  attr :tone, :string, default: "danger", values: ~w(danger neutral)
  attr :size, :string, default: "sm", values: ~w(sm md lg)
  attr :fill, :boolean, default: false, doc: "the trigger fills its row: a single object's page"

  attr :trigger, :string,
    default: nil,
    values: [nil, "quiet"],
    doc: "`quiet`: a mark in ink-3 rather than a red outline, e.g. a list's ×"

  attr :aria_label, :string, default: nil, doc: "the trigger's, when its words are a mark"
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil, doc: "the wrapper's: its place in the row"
  attr :rest, :global, include: ~w(form name value)

  def confirm(assigns) do
    assigns =
      assign(assigns,
        ask: assigns.id <> "-ask",
        panel: assigns.id <> "-confirm",
        keep: assigns.id <> "-keep"
      )

    ~H"""
    <div class={["ui-confirm", "ui-confirm--#{@tone}", @fill && "ui-confirm--fill", @class]}>
      <.button
        id={@ask}
        type="button"
        variant={trigger_variant(@trigger, @tone)}
        size={@size}
        class={[@fill && "w-full", @trigger == "quiet" && "ui-confirm-quiet"]}
        disabled={@disabled}
        aria-label={@aria_label}
        aria-controls={@panel}
        phx-click={
          JS.hide(to: "#" <> @ask)
          |> JS.show(to: "#" <> @panel, display: "flex")
          |> JS.focus(to: "#" <> @keep)
        }
      >
        {@label}
      </.button>
      <div id={@panel} class="ui-confirm-panel" role="group" aria-label={@label} style="display: none">
        <p class="ui-confirm-sentence">{@sentence}</p>
        <div class="ui-confirm-actions">
          <.button
            id={@keep}
            type="button"
            variant="secondary"
            size={@size}
            phx-click={
              JS.hide(to: "#" <> @panel)
              |> JS.show(to: "#" <> @ask, display: "inline-flex")
              |> JS.focus(to: "#" <> @ask)
            }
          >
            Keep it
          </.button>
          <.button
            id={@id}
            type="button"
            variant={if @tone == "danger", do: "danger", else: "outline"}
            size={@size}
            disabled={@disabled}
            {@rest}
          >
            {@act}
          </.button>
        </div>
      </div>
    </div>
    """
  end

  defp trigger_variant("quiet", _tone), do: "quiet"
  defp trigger_variant(nil, "danger"), do: "danger"
  defp trigger_variant(nil, "neutral"), do: "secondary"
end
