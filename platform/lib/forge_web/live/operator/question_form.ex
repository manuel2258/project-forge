defmodule ForgeWeb.Operator.QuestionForm do
  @moduledoc """
  A document's questions, answered together: one card, a tab per question, a choice row per
  option, a free-text field per question, and one Send. `docs/design/ui.md` § The question card
  is the standard.

  **Answering a question locks it in; only Send sends.** A job that stopped with three questions
  used to resume on the answer that closed the last blocking one, and read whichever answers had
  landed by then. One Send makes them arrive together.

  **One question shows at a time, under its tab**, and every other one is in the form all the same,
  drawn `hidden`: what is sent is the whole card whichever tab shows. The tab is the page's state
  (`form:open`), so a re-render keeps it.

  **Enter never sends.** The free-text field is `ForgeWeb.Conversations.message_box/1` with Enter a
  new line: a one-line input submitted the form on Enter, before the questions after it were read.
  And the form swallows Enter from its inputs (`.EnterNeverSends`), since a browser may submit on
  Enter from a radio as well.

  **The page holds the draft, and only the page.** Every change event carries the whole form —
  every question's radios and field, shown or not — so what the socket keeps under `:forms` is
  the form's last state and nothing else. A form nobody has touched is its recommendations.
  Reloading starts again from them, and nobody else sees a half-answer.

  The same form serves a ticket's document (sent with `questions:send`, as
  `Forge.Operator.answer_all/4`) and a conversation's reply (`chat:questions:send`, as
  `Forge.Operator.answer_chat/4`). A chat's questions are all required because a chat's parser
  reads every question as blocking (`Forge.Conversations.questions/1`); the form needs no flag
  to know it.
  """

  use ForgeWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  require Logger

  alias Forge.Artifacts.Answer
  alias Forge.{Conversations, Operator, Tickets}
  alias ForgeCore.Document.Question
  alias ForgeWeb.Operator.Actions

  @doc "The draft state a page starts with: no form touched."
  def init, do: %{}

  @doc """
  One document's questions as the question card (`docs/design/ui.md` § The question card): one
  tab per question, the shown one's text, options and own words, and the foot with what is left
  and Send.

  `id` names the draft; it must change when the questions do — a version id, or a chat reply's
  `Forge.Conversations.reply_ref/1` — so that a draft never outlives what it was drawn for.

  **Every question is in the form whichever tab shows**: the others are drawn `hidden`, their
  inputs still in the form, so every change event and the Send carry the whole draft.

  `:dock` is drawn in the foot beside Send — the queue's *Later*.
  """
  attr :id, :string, required: true
  attr :questions, :list, required: true
  attr :forms, :map, required: true, doc: "the page's `:forms` assign"
  attr :submit, :string, required: true
  attr :hidden, :list, default: [], doc: "`{name, value}` pairs sent with the form"
  attr :refusal, :map, default: nil, doc: "the page's `:refusal`: a Send refused is drawn here"

  attr :any_refusal, :boolean,
    default: true,
    doc: """
    draw any card's refused Send, not only this one's: a stale card is drawn again under another
    id, and the card standing in its place is where the person looks. False for a card beside
    another that takes them.
    """

  slot :dock, doc: "drawn in the foot, before Send"

  def question_form(assigns) do
    questions = Enum.sort_by(assigns.questions, & &1.line)
    state = state(assigns.forms, assigns.id, questions)
    required = Enum.filter(questions, & &1.blocking)

    assigns =
      assign(assigns,
        questions: questions,
        state: state,
        shown: shown(state, questions),
        left: Enum.count(required, &(not locked?(state.answers[&1.key]))),
        locked: Enum.count(questions, &locked?(state.answers[&1.key])),
        # "Blocking" tells a required question from an optional one; where every question is
        # required — a chat's always — the word tells nothing apart.
        kind: if(length(required) == length(questions), do: "", else: "blocking ")
      )

    ~H"""
    <form
      id={"form-#{@id}"}
      phx-change="form:change"
      phx-submit={@submit}
      phx-hook=".EnterNeverSends"
      class="qcard"
    >
      <input type="hidden" name="form" value={@id} />
      <input :for={{name, value} <- @hidden} type="hidden" name={name} value={value} />

      <%!-- One tab per question, in the order the agent wrote them; ● once its answer is locked
            in. A tab is a button and not a link: it changes what the card shows and sends
            nothing. --%>
      <div :if={length(@questions) > 1} class="qcard-tabs" role="tablist">
        <button
          :for={question <- @questions}
          id={"tab-#{@id}-#{question.key}"}
          type="button"
          role="tab"
          aria-selected={to_string(question.key == @shown)}
          class={["qcard-tab", question.key == @shown && "qcard-tab--on"]}
          phx-click="form:open"
          phx-value-form={@id}
          phx-value-key={question.key}
        >
          <span aria-hidden="true">{if locked?(@state.answers[question.key]), do: "●", else: "○"}</span>
          {question.key}
        </button>
      </div>

      <div class="qcard-body">
        <div
          :for={{question, index} <- Enum.with_index(@questions, 1)}
          id={"question-#{@id}-#{question.key}"}
          data-shown={question.key == @shown}
          hidden={question.key != @shown}
        >
          <.question
            form={@id}
            question={question}
            answer={@state.answers[question.key]}
            optional={not question.blocking}
            position={length(@questions) > 1 && "#{index} of #{length(@questions)}"}
          />
        </div>
      </div>

      <div class="qcard-foot">
        <Actions.refused
          id={"form-#{@id}-refusal"}
          refusal={@refusal}
          at={if @any_refusal, do: [:questions], else: [{:form, @id}]}
        />
        <p :if={@left > 0} class="qcard-left" id={"form-#{@id}-left"}>
          {@left} {@kind}{if @left == 1, do: "question", else: "questions"} left
        </p>
        <div class="qcard-dock">
          {render_slot(@dock)}
          <.button
            type="submit"
            variant="primary"
            fill
            disabled={@left > 0 or @locked == 0}
            phx-disable-with="Sending…"
          >
            Send {@locked} {if @locked == 1, do: "answer", else: "answers"}
          </.button>
        </div>
      </div>
    </form>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".EnterNeverSends">
      export default {
        mounted() {
          // A browser may submit a form on Enter from one of its inputs — a radio, in some — and
          // only Send sends (`docs/design/ui.md` § The affordance rule). The free text is a
          // textarea, where Enter is a new line. No ExUnit test can press a key; what the tests
          // pin is that the form carries this hook.
          this.el.addEventListener("keydown", (event) => {
            if (event.key === "Enter" && event.target.tagName === "INPUT") event.preventDefault()
          })
        }
      }
    </script>
    """
  end

  attr :form, :string, required: true
  attr :question, :map, required: true
  attr :answer, :map, required: true
  attr :optional, :boolean, required: true
  attr :position, :any, required: true, doc: "`1 of 2`, or false for a card of one"

  defp question(assigns) do
    ~H"""
    <div role="group" aria-label={@question.text} class="qcard-question">
      <span :if={@position} class="qcard-position">{@position}</span>

      <%!-- Not accent: accent is spent on what waits (`docs/design/ui.md` § Colour), and the
            passage a question is about is context, drawn beside an assumption too. --%>
      <blockquote :if={@question.anchor} class="qcard-anchor">{@question.anchor}</blockquote>

      <p class="qcard-text">
        <span>{@question.text}</span>
        <span :if={@optional} class="ui-badge">optional</span>
      </p>

      <p :if={@question.assumption} class="qcard-assumed">Assumed: {@question.assumption}</p>

      <div :if={@question.options != []} class="qcard-options">
        <.choice_row
          :for={{option, index} <- Enum.with_index(@question.options)}
          id={"choice-#{@form}-#{@question.key}-#{index}"}
          name={"answers[#{@question.key}][choice]"}
          value={option.label}
          label={option.label}
          detail={option.detail}
          recommended={option.recommended}
          selected={@answer["choice"] == option.label}
        />

        <%!-- A radio of its own, so clearing is part of the form's state like choosing is. Without
              it a recommendation that started chosen could never become an answer in your own
              words. --%>
        <label :if={@answer["choice"]} class="qcard-clear">
          <input
            type="radio"
            name={"answers[#{@question.key}][choice]"}
            value=""
            class="sr-only"
          /> Clear choice
        </label>
      </div>

      <ForgeWeb.Conversations.message_box
        id={"answer-#{@form}-#{@question.key}"}
        name={"answers[#{@question.key}][text]"}
        value={@answer["text"]}
        enter={:newline}
        aria-label={"Your own words on: #{@question.text}"}
        placeholder={
          if @question.options == [],
            do: "answer in your own words",
            else: "add a note, or answer in your own words"
        }
      />
    </div>
    """
  end

  @doc """
  The split pane a question card sits in, under the content it is about (`docs/design/ui.md`
  § The question card): a 16px handle above the card, which is sized to what it holds up to a
  limit the person sets by dragging the handle. Tapping the handle folds the card to its tabs and
  Send. **The limit is kept per device**, in the browser's storage, by the `.SplitPane` hook;
  the server never draws it, so a patch does not take it away.
  """
  attr :id, :string, required: true
  slot :inner_block, required: true

  def split_pane(assigns) do
    ~H"""
    <div
      id={@id}
      class="qpane"
      phx-hook=".SplitPane"
      phx-mounted={JS.ignore_attributes(["style", "data-folded"])}
    >
      <button type="button" class="qpane-handle" aria-label="Fold or resize the questions">
        <span aria-hidden="true" />
      </button>
      {render_slot(@inner_block)}
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".SplitPane">
      // The limit is a height in pixels under one key for every card on this device: a limit that
      // suits a phone does not suit a monitor, and nothing asked for it to follow a person.
      const KEY = "forge:split-limit"
      const MIN = 120

      const stored = () => {
        try { return parseInt(localStorage.getItem(KEY), 10) || null } catch (_) { return null }
      }

      export default {
        mounted() {
          const handle = this.el.querySelector(".qpane-handle")
          const apply = (px) => { if (px) this.el.style.setProperty("--split-limit", `${px}px`) }
          apply(stored())

          handle.addEventListener("pointerdown", (down) => {
            const body = this.el.querySelector(".qcard-body")
            const start = body ? body.getBoundingClientRect().height : MIN
            const y0 = down.clientY
            let moved = false
            handle.setPointerCapture(down.pointerId)

            const move = (event) => {
              const dy = y0 - event.clientY
              if (Math.abs(dy) > 4) moved = true
              if (!moved) return
              const max = Math.round(window.innerHeight * 0.85)
              const px = Math.min(Math.max(Math.round(start + dy), MIN), max)
              this.limit = px
              this.el.removeAttribute("data-folded")
              apply(px)
            }

            const up = () => {
              handle.removeEventListener("pointermove", move)
              handle.removeEventListener("pointerup", up)
              handle.removeEventListener("pointercancel", up)
              if (!moved) {
                this.el.toggleAttribute("data-folded")
              } else if (this.limit) {
                try { localStorage.setItem(KEY, String(this.limit)) } catch (_) {}
              }
            }

            handle.addEventListener("pointermove", move)
            handle.addEventListener("pointerup", up)
            handle.addEventListener("pointercancel", up)
          })

          // A keyboard press of the handle folds and unfolds it too.
          handle.addEventListener("click", (event) => {
            if (event.detail === 0) this.el.toggleAttribute("data-folded")
          })
        }
      }
    </script>
    """
  end

  @doc """
  Splits `assumed` into those asked in the same document as one of `blocking` — which are answered
  in that document's form, optional — and those asked on their own: `{joined, alone}`. `version`
  reads an item's artifact version id, so the queue's items and a ticket's questions are split by
  the one rule (`docs/design/ui.md` § The question card).
  """
  def join_assumed(blocking, assumed, version \\ & &1.artifact_version_id) do
    held = MapSet.new(blocking, version)
    Enum.split_with(assumed, &MapSet.member?(held, version.(&1)))
  end

  # -- state -----------------------------------------------------------------------------------

  @doc """
  A form's draft: `answers` by key, each `%{"choice" => label | nil, "text" => text | nil}`,
  and the tab last chosen or touched, or nil. Untouched, a form's answers are its
  recommendations.
  """
  def state(forms, id, questions) do
    form = Map.get(forms, id, %{})

    %{
      answers: Map.get(form, :answers) || recommendations(questions),
      tab: Map.get(form, :tab)
    }
  end

  defp recommendations(questions) do
    Map.new(questions, fn question ->
      choice =
        case Question.recommended(question) do
          nil -> nil
          option -> option.label
        end

      {question.key, %{"choice" => choice, "text" => nil}}
    end)
  end

  defp locked?(%{"choice" => choice, "text" => text}), do: choice != nil or text != nil
  defp locked?(_answer), do: false

  # The tab shown: the one chosen or last touched, while it is still one of the card's; else the
  # first question with nothing locked in, else the first. Kept rather than recomputed on every
  # change, so locking an answer in does not move the card to another question under the thumb.
  defp shown(state, questions) do
    keys = Enum.map(questions, & &1.key)

    cond do
      state.tab in keys -> state.tab
      first = Enum.find(questions, &(not locked?(state.answers[&1.key]))) -> first.key
      true -> List.first(keys)
    end
  end

  # -- events ----------------------------------------------------------------------------------

  @doc """
  Handles a form event. `{:state, socket}` for a change to the draft, which needs no reload;
  `{:handled, socket}` for a Send, after which the page reloads; `:unknown` for anything else,
  a malformed event included.

  Everything here arrives off the wire — ids, answers, the reply a form was drawn for — so a
  payload of the wrong shape is ignored rather than raised on, and an id naming nothing is said
  as a refusal of Send (`ForgeWeb.Operator.Actions.refuse/3`), which the card draws in its foot.
  Every write goes through `Forge.Operator`, which checks membership.
  """
  # Clears the last refusal first, as `ForgeWeb.Operator.Actions.handle/3` does: a chat's page
  # hands its card's events straight here.
  def handle(event, params, socket) do
    dispatch(event, params, Phoenix.Component.assign(socket, :refusal, nil))
  rescue
    Ecto.NoResultsError -> {:handled, refused(socket, params["form"], :gone)}
  end

  # A change naming no form is dropped by the pattern. Dropping it is an equivalent mutant rather
  # than a guard: stored, it would sit under an id no form is drawn with.
  defp dispatch("form:change", %{"form" => id} = params, socket) do
    answers = params |> answers_of() |> Map.new(fn {key, a} -> {key, answer(a)} end)
    form = Map.get(forms(socket), id, %{})

    # The question touched is the one on screen: kept, so the card stays on it.
    tab =
      case params["_target"] do
        ["answers", key, _field] -> key
        _other -> Map.get(form, :tab)
      end

    {:state, put_form(socket, id, %{answers: answers, tab: tab})}
  end

  defp dispatch("form:open", %{"form" => id, "key" => key}, socket) do
    form = Map.get(forms(socket), id, %{})
    {:state, put_form(socket, id, Map.put(form, :tab, key))}
  end

  # A sent form starts again from its recommendations: what is left on it — an assumption not
  # sent — is drawn as the agent asked it, not as the draft left it.
  defp dispatch("questions:send", %{"form" => id, "ticket" => ticket_id} = params, socket) do
    ticket = Actions.row!(ticket_id, &Tickets.get!/1, Forge.Tickets.Ticket)
    answers = sent(params)

    case Operator.answer_all(ticket, Actions.user(socket), params["version"], answers) do
      {:ok, _ticket} ->
        count = map_size(answers)

        {:handled,
         socket
         |> forget(id)
         |> put_flash(:info, "Sent #{count} #{if count == 1, do: "answer", else: "answers"}")}

      {:error, reason} ->
        {:handled, refused(socket, id, reason)}
    end
  end

  defp dispatch("chat:questions:send", %{"form" => id, "chat" => chat_id} = params, socket) do
    chat = Actions.row!(chat_id, &Conversations.get!/1, Forge.Jobs.Job)

    # Forgetting here is housekeeping, an equivalent mutant: once the answer is sent the last
    # thing said is the person's, so no form is drawn for that reply again.
    case Operator.answer_chat(chat, Actions.user(socket), params["reply"], sent(params)) do
      {:ok, _event} -> {:handled, forget(socket, id)}
      {:error, reason} -> {:handled, refused(socket, id, reason)}
    end
  end

  defp dispatch(_event, _params, _socket), do: :unknown

  # The answers a payload carries, keyed by question: anything but a map of maps is none.
  defp answers_of(params) do
    case Map.get(params, "answers") do
      answers when is_map(answers) -> Map.filter(answers, fn {key, _a} -> is_binary(key) end)
      _other -> %{}
    end
  end

  # What Send carries, as the operations take it: a question left with neither a choice nor text
  # is not answered — an optional one skipped, or a required one the operation will name.
  defp sent(params) do
    params
    |> answers_of()
    |> Enum.flat_map(fn {key, a} ->
      case answer(a) do
        %{"choice" => nil, "text" => nil} -> []
        %{"choice" => choice, "text" => text} -> [{key, %{choice: choice, text: text}}]
      end
    end)
    |> Map.new()
  end

  defp answer(params) when is_map(params),
    do: %{"choice" => blank(params["choice"]), "text" => blank(params["text"])}

  defp answer(_params), do: %{"choice" => nil, "text" => nil}

  # Off the wire, anything but text is no answer at all.
  defp blank(value) when is_binary(value), do: Answer.blank(value)
  defp blank(_value), do: nil

  # A page that never drew a form has no `:forms` yet; an event naming one is still handled.
  defp forms(socket), do: Map.get(socket.assigns, :forms, %{})

  defp put_form(socket, id, form),
    do: Phoenix.Component.assign(socket, :forms, Map.put(forms(socket), id, form))

  defp forget(socket, id),
    do: Phoenix.Component.assign(socket, :forms, Map.delete(forms(socket), id))

  # **The draft is kept with a stale refusal.** The form was stale because the document has a
  # newer version — whose form is under another id, so the draft is simply never read again — or
  # because someone answered one of its questions meanwhile, when the same form is drawn again for
  # the questions still asked, and what the person locked in for those is still what they meant.
  # Left for the card whose Send it was (`{:form, id}`), and drawn in that card's foot.
  defp refused(socket, id, :gone),
    do: Actions.refuse(socket, {:form, id}, "That no longer exists.")

  defp refused(socket, id, :stale) do
    Actions.refuse(
      socket,
      {:form, id},
      "Some of these questions were answered or changed since the page showed them. " <>
        "Nothing was sent; check what is still asked and send again."
    )
  end

  defp refused(socket, id, :not_live),
    do: Actions.refuse(socket, {:form, id}, "This conversation has stopped. Reopen it to answer.")

  defp refused(socket, id, reason),
    do: Actions.refuse(socket, {:form, id}, "Not sent: #{why(reason)}")

  defp why({:unanswered, keys}), do: "answer #{Enum.join(keys, ", ")} first"
  defp why({:not_an_option, key, choice}), do: "#{inspect(choice)} is not an option of #{key}"
  defp why(:no_answers), do: "nothing is answered"
  defp why(:forbidden), do: "that is not yours to answer"

  # Two Sends of one form at the same moment: the second one's `answers.md` version collides with
  # the first one's and is refused whole. Said in words — the changeset holds the whole document.
  # No test reaches it: it takes two transactions open at once, which the SQL sandbox serialises,
  # and one after the other the second is refused as stale instead.
  defp why(%Ecto.Changeset{}), do: "it was answered from somewhere else at the same moment"

  defp why(other) do
    Logger.error("question form send failed: #{inspect(other)}")
    "something went wrong; see the server log"
  end
end
