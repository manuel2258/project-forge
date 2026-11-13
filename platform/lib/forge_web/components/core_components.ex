defmodule ForgeWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as buttons, forms and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, with the design's tokens as its theme
  (`assets/css/tokens.css`, `docs/design/ui.md` § Tokens): `bg-surface-2`, `text-ink-3`,
  `border-border`, `text-danger`. There is no component library and no icon set; a state is a
  Unicode mark (`docs/design/ui.md` § Marks). Here are useful references:

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: ForgeWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  The one button (`actions/Button`, `docs/design/ui.md` § The affordance rule): `primary` filled
  ink is the next step, `decision` amber waits on you and leads with ◆, `outline` navigates,
  `danger` destroys. A `navigate`, `patch` or `href` draws it as a link.

  **`chevron` is drawn on a link only.** `›` says the button goes somewhere (`docs/design/ui.md`
  § Marks); on a Send, a submit or a click that commits in place it promised a page that never
  came, on exactly the buttons where certainty matters (UX pass, A7).

  **Disabled keeps its size and place** — the same element at 45 % — and is never hidden.

  ## Examples

      <.button variant="primary" fill>Send 1 answer</.button>
      <.button variant="decision" size="md">Approve</.button>
      <.button variant="outline" chevron navigate={~p"/"}>Review the changeset</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form replace)

  attr :class, :any,
    default: nil,
    doc: "added to the button's own classes, for its width or place"

  # The contract's default is `primary`. Here it is `secondary`, because every call site written
  # before the primitives passed no variant and meant a bordered button; defaulting them to
  # filled ink would put two filled buttons side by side on a dozen pages.
  attr :variant, :string,
    default: "secondary",
    values: ~w(primary decision decision-open outline secondary neutral danger quiet link)

  # The contract's default is `xl` (52); here `lg` (48), the height every existing call site was
  # drawn at, until each area's slice picks its sizes.
  attr :size, :string, default: "lg", values: ~w(xl lg md sm desk)
  attr :fill, :boolean, default: false, doc: "grow to fill the row: the one primary in a dock"
  attr :chevron, :boolean, default: false, doc: "a trailing › for an action that goes somewhere"

  attr :diamond, :boolean,
    default: nil,
    doc: "a leading ◆; on by default for the decision variants"

  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    link? = (rest[:href] || rest[:navigate] || rest[:patch]) != nil
    chevron = assigns.chevron and link?

    assigns =
      assigns
      |> assign(:diamond, diamond?(assigns.diamond, assigns.variant))
      |> assign(:chevron, chevron)
      |> assign(:class, [
        "ui-btn",
        "ui-btn--#{assigns.variant}",
        "ui-btn--#{assigns.size}",
        assigns.fill && "ui-btn--fill",
        chevron && "ui-btn--chevron",
        assigns.class
      ])

    if link? do
      ~H"""
      <.link class={@class} {@rest}>
        <span :if={@diamond} class="ui-btn-diamond" aria-hidden="true">◆</span>
        <span>{render_slot(@inner_block)}</span>
        <span :if={@chevron} aria-hidden="true">›</span>
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        <span :if={@diamond} class="ui-btn-diamond" aria-hidden="true">◆</span>
        <span>{render_slot(@inner_block)}</span>
      </button>
      """
    end
  end

  defp diamond?(nil, variant), do: variant in ~w(decision decision-open)
  defp diamond?(diamond, _variant), do: diamond

  @doc """
  A field (`forms/Field`): the label above, the hint or the errors below, each error under the
  input it belongs to and in the server's words, the input marked `aria-invalid` and pointing at
  them (`docs/design/ui.md` § Errors stay where you acted).

  A `Phoenix.HTML.FormField` may be passed as `field`, which gives the name, id, value and errors;
  otherwise all of them may be passed explicitly. `multiline` (or `type="textarea"`) draws a
  textarea, `mono` sets the value in mono (a name, a URL, a key), `desk` draws the desktop size.

  `type="select"` takes `options` (and `prompt`); `type="checkbox"` is a boolean field. A choice
  between a few visible options is a `ForgeWeb.UI.Forms.choice_row/1` rather than either.

  ## Examples

      <.input field={@form[:name]} label="Name" mono hint="Lowercase, digits and hyphens." />
      <.input name="note" multiline errors={["can't be blank"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :hint, :string, default: nil, doc: "said under the field while it has no error"
  attr :mono, :boolean, default: false
  attr :multiline, :boolean, default: false, doc: "a textarea, as `type=\"textarea\"`"
  attr :desk, :boolean, default: false, doc: "the desktop size: 34px, 13px"
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "added to the input's own classes"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{multiline: true, type: "text"} = assigns),
    do: input(%{assigns | multiline: false, type: "textarea"})

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="ui-field">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="flex min-h-11 items-center gap-2.5 text-ui text-ink-2">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "size-4"}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@errors != [] && error_id(@id)}
            {@rest}
          />{@label}
        </span>
      </label>
      <.field_errors id={@id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class={field_class(assigns)}>
      <label :if={@label} for={@id} class="ui-field-label">{@label}</label>
      <select
        id={@id}
        name={@name}
        class={["ui-field-input", @class]}
        multiple={@multiple}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={described_by(@id, @errors, @hint)}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.field_errors id={@id} errors={@errors} hint={@hint} />
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={field_class(assigns)}>
      <label :if={@label} for={@id} class="ui-field-label">{@label}</label>
      <textarea
        id={@id}
        name={@name}
        class={["ui-field-input", @class]}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={described_by(@id, @errors, @hint)}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.field_errors id={@id} errors={@errors} hint={@hint} />
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class={field_class(assigns)}>
      <label :if={@label} for={@id} class="ui-field-label">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={["ui-field-input", @class]}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={described_by(@id, @errors, @hint)}
        {@rest}
      />
      <.field_errors id={@id} errors={@errors} hint={@hint} />
    </div>
    """
  end

  defp field_class(assigns),
    do: ["ui-field", assigns.mono && "ui-field--mono", assigns.desk && "ui-field--desk"]

  defp described_by(id, errors, hint) do
    cond do
      errors != [] -> error_id(id)
      hint -> hint_id(id)
      true -> nil
    end
  end

  defp error_id(nil), do: nil
  defp error_id(id), do: "#{id}-error"
  defp hint_id(nil), do: nil
  defp hint_id(id), do: "#{id}-hint"

  attr :id, :any, required: true
  attr :errors, :list, required: true
  attr :hint, :string, default: nil

  # The errors under their own field; the hint only while there are none (`forms/Field`).
  defp field_errors(assigns) do
    ~H"""
    <div :if={@errors != []} id={error_id(@id)} class="flex flex-col gap-1">
      <p :for={msg <- @errors} class="ui-field-error">{msg}</p>
    </div>
    <p :if={@errors == [] and @hint} id={hint_id(@id)} class="ui-field-hint">{@hint}</p>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(ForgeWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(ForgeWeb.Gettext, "errors", msg, opts)
    end
  end
end
