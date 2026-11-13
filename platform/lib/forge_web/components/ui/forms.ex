defmodule ForgeWeb.UI.Forms do
  @moduledoc """
  The form primitives (`docs/design/ui/design_system/components/forms/`, `docs/design/ui.md`
  § Components) other than the field itself, which is `ForgeWeb.CoreComponents.input/1`: the
  segmented switch, the choice row, the stepper and the composer.

  Every one of them is a real form control — a radio, a checkbox, a number, a textarea — so a
  form's `phx-change` sees it and a reconnect restores it (`docs/design/ui.md` § A reconnect is
  not a reload). None of them submits but the composer's send.

  Styles are in `assets/css/components.css` under the same names.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  An equal-width switch of 2–4 short, mutually exclusive options (`forms/Segmented`): API access,
  effort, *Admit as*, sub-views. Never wraps.

  With a `name`, each option is a radio in the form, and the selected one follows the radio
  rather than waiting for the server. Without one, each option is a button sending `on_select`
  with `phx-value-value`, for a switch that is not part of a form. The button carries the same
  `value` too: LiveView sends a clicked button's own `value` over `phx-value-value`, so a button
  without one sent `""` in a real browser, which no `render_click` in a test reproduces.

  `options` are strings, `{label, value}` pairs, or `{label, value, count}` triples: a count is
  drawn as the grey count bubble beside its label, never run into it (`Open 8Admitted 1` read as
  one word), and a zero as a muted bubble.
  """
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :options, :list, required: true
  attr :value, :any, default: nil
  attr :on_select, :any, default: nil
  attr :size, :string, default: "lg", values: ~w(lg md sm xs)
  attr :rest, :global

  def segmented(assigns) do
    assigns = assign(assigns, :options, Enum.map(assigns.options, &option/1))

    ~H"""
    <div id={@id} role="radiogroup" class={["ui-seg", @size != "lg" && "ui-seg--#{@size}"]} {@rest}>
      <%= if @name do %>
        <label :for={{label, value, count} <- @options} class="ui-seg-opt">
          <input
            type="radio"
            class="sr-only"
            name={@name}
            value={value}
            checked={to_string(value) == to_string(@value)}
          />{label}<.seg_count count={count} />
        </label>
      <% else %>
        <button
          :for={{label, value, count} <- @options}
          type="button"
          role="radio"
          class="ui-seg-opt"
          aria-checked={to_string(to_string(value) == to_string(@value))}
          phx-click={@on_select}
          value={value}
          phx-value-value={value}
        >
          {label}<.seg_count count={count} />
        </button>
      <% end %>
    </div>
    """
  end

  defp option({label, value, count}), do: {label, value, count}
  defp option({label, value}), do: {label, value, nil}
  defp option(label), do: {label, label, nil}

  attr :count, :any, required: true

  defp seg_count(%{count: nil} = assigns), do: ~H""

  defp seg_count(assigns) do
    ~H"""
    <ForgeWeb.UI.Data.count_bubble value={@count} muted={@count == 0} />
    """
  end

  @doc """
  A visible choice as a full-width row (`forms/ChoiceRow`): an answer, a way forward, a git scope.
  A radio, or a checkbox with `multi`. **It selects and never commits** — it is a form input, not
  a button, and the dock's button is what commits (`docs/design/ui.md` § The affordance rule).

  52px with a `detail`, 46 without, 32 at `desk` size. `recommended` adds the badge.
  """
  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :label, :string, required: true
  attr :detail, :string, default: nil
  attr :selected, :boolean, default: false
  attr :recommended, :boolean, default: false
  attr :multi, :boolean, default: false
  attr :desk, :boolean, default: false
  attr :rest, :global, include: ~w(disabled form), doc: "for the input: phx-click, disabled"

  def choice_row(assigns) do
    ~H"""
    <label
      for={@id}
      class={[
        "ui-choice",
        @multi && "ui-choice--multi",
        @detail && !@desk && "ui-choice--detail",
        @desk && "ui-choice--desk"
      ]}
    >
      <input
        id={@id}
        type={if @multi, do: "checkbox", else: "radio"}
        class="sr-only"
        name={@name}
        value={@value}
        checked={@selected}
        {@rest}
      />
      <span class="ui-choice-mark" aria-hidden="true" />
      <span class="ui-choice-text">
        <span class="ui-choice-label">{@label}</span>
        <span :if={@detail} class="ui-choice-detail">{@detail}</span>
      </span>
      <span :if={@recommended} class="ui-badge">recommended</span>
    </label>
    """
  end

  @doc """
  A small integer (`forms/Stepper`): days, max machines, idle minutes. The value is a number input
  in the form; − and + step it in the browser and fire `input`, so the form's `phx-change` runs
  as if it had been typed (`forge:step` in `assets/js/app.js`). `min` and `max` bound both.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :integer, default: 0
  attr :min, :integer, default: 0
  attr :max, :integer, default: 999
  attr :desk, :boolean, default: false
  attr :label, :string, default: nil, doc: "for assistive technology, when no label is beside it"
  attr :rest, :global, include: ~w(disabled form)

  def stepper(assigns) do
    ~H"""
    <span class={["ui-stepper", @desk && "ui-stepper--desk"]}>
      <button
        type="button"
        class="ui-stepper-btn"
        aria-label="Less"
        phx-click={step(@id, -1)}
        disabled={@rest[:disabled]}
      >
        −
      </button>
      <input
        id={@id}
        type="number"
        inputmode="numeric"
        class="ui-stepper-value"
        name={@name}
        value={@value}
        min={@min}
        max={@max}
        step="1"
        aria-label={@label}
        {@rest}
      />
      <button
        type="button"
        class="ui-stepper-btn"
        aria-label="More"
        phx-click={step(@id, 1)}
        disabled={@rest[:disabled]}
      >
        +
      </button>
    </span>
    """
  end

  defp step(id, by), do: JS.dispatch("forge:step", to: "#" <> id, detail: %{by: by})

  @doc """
  The reply composer (`forms/Composer`), 64px: a round field with send as an icon inside it,
  **never a filled button**, so a message never looks like a decision. `interrupt` names the
  cost while the agent is responding: *Interrupt and send*.

  Draw it inside the caller's form; send submits it. The field grows from one line to six and
  then scrolls inside itself. **Enter sends on a keyboard and ends a line on a phone**
  (`enter={:send}`), or always ends a line (`enter={:newline}`) where the box is one field of a
  larger form; shift-Enter always ends a line, and an input method's Enter is never a send.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: nil
  attr :placeholder, :string, default: "Reply to the agent"
  attr :interrupt, :boolean, default: false
  attr :enter, :atom, values: [:send, :newline], default: :send
  attr :disabled, :boolean, default: false
  attr :label, :string, default: nil, doc: "for assistive technology; the placeholder otherwise"
  attr :rest, :global, doc: "for the textarea: phx-debounce"

  def composer(assigns) do
    ~H"""
    <div class="ui-composer">
      <div class="ui-composer-field">
        <textarea
          id={@id}
          name={@name}
          rows="1"
          phx-hook=".Composer"
          data-newline-on={newline_on(@enter)}
          data-max-lines="6"
          placeholder={@placeholder}
          aria-label={@label || @placeholder}
          disabled={@disabled}
          class="ui-composer-input"
          {@rest}
        >{@value}</textarea>
        <button
          :if={@interrupt}
          type="submit"
          class="ui-composer-send ui-composer-send--words"
          disabled={@disabled}
        >
          Interrupt and send
        </button>
        <button
          :if={!@interrupt}
          type="submit"
          class="ui-composer-send"
          aria-label="Send"
          disabled={@disabled}
        >
          <svg
            width="18"
            height="18"
            viewBox="0 0 18 18"
            fill="none"
            stroke="currentColor"
            stroke-width="1.6"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M9 14V4M4.5 8.5 9 4l4.5 4.5" />
          </svg>
        </button>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
      export default {
        mounted() {
          this.coarse = window.matchMedia(this.el.dataset.newlineOn)

          this.el.addEventListener("keydown", (event) => {
            if (event.key !== "Enter" || event.shiftKey) return

            // An input method editor uses Enter to commit the character being composed. Sending
            // then would send half a word, so composition always wins.
            if (event.isComposing || event.keyCode === 229) return

            // A phone, or a box that is one field of a larger form (`all`): Enter is how a line
            // is ended, and Send is how a message is sent. No ExUnit test can press a key, so
            // deleting this line fails nothing there; what the tests pin is the query it reads,
            // `data-newline-on`.
            if (this.coarse.matches) return

            event.preventDefault()
            this.el.form?.requestSubmit()
          })

          this.el.addEventListener("input", () => this.fit())
          this.fit()
        },

        updated() { this.fit() },

        // From one line to six, then it scrolls inside itself.
        fit() {
          const style = getComputedStyle(this.el)
          const edges = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom) +
            parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth)
          const most = parseFloat(style.lineHeight) * Number(this.el.dataset.maxLines) + edges

          this.el.style.height = "auto"
          const wanted = this.el.scrollHeight + parseFloat(style.borderTopWidth) +
            parseFloat(style.borderBottomWidth)
          this.el.style.height = `${Math.min(wanted, most)}px`
          this.el.style.overflowY = wanted > most ? "auto" : "hidden"
        }
      }
    </script>
    """
  end

  @doc """
  The media query under which Enter ends a line rather than sending: a coarse pointer (a phone)
  for `:send`, always for `:newline`. Read by the composer's hook from `data-newline-on`.
  """
  @spec newline_on(:send | :newline) :: String.t()
  def newline_on(:newline), do: "all"
  def newline_on(:send), do: "(pointer: coarse)"
end
