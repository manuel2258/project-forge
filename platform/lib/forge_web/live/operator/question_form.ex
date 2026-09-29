defmodule ForgeWeb.Operator.QuestionForm do
  @moduledoc """
  A document's questions, answered together: one form, an option card per choice, a free-text
  field per question, and one Send. `docs/design/ui.md` § Answering questions is the standard.

  **Answering a question locks it in; only Send sends.** A job that stopped with three questions
  used to resume on the answer that closed the last blocking one, and read whichever answers had
  landed by then. One Send makes them arrive together.

  **The page holds the draft, and only the page.** Every change event carries the whole form —
  an open question as its radios and field, a folded one as hidden inputs — so what the socket
  keeps under `:forms` is the form's last state and nothing else. A form nobody has touched is
  its recommendations. Reloading starts again from them, and nobody else sees a half-answer.

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
  One document's questions as a form.

  `id` names the draft; it must change when the questions do — a version id, or a chat reply's
  `Forge.Conversations.reply_ref/1` — so that a draft never outlives what it was drawn for.
  """
  attr :id, :string, required: true
  attr :questions, :list, required: true
  attr :forms, :map, required: true, doc: "the page's `:forms` assign"
  attr :submit, :string, required: true
  attr :hidden, :list, default: [], doc: "`{name, value}` pairs sent with the form"

  def question_form(assigns) do
    questions = Enum.sort_by(assigns.questions, & &1.line)
    state = state(assigns.forms, assigns.id, questions)
    required = Enum.filter(questions, & &1.blocking)

    assigns =
      assign(assigns,
        questions: questions,
        state: state,
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
      class="flex flex-col gap-4"
    >
      <input type="hidden" name="form" value={@id} />
      <input :for={{name, value} <- @hidden} type="hidden" name={name} value={value} />

      <div :for={question <- @questions} id={"question-#{@id}-#{question.key}"}>
        <.open_question
          :if={open?(@state, question)}
          form={@id}
          question={question}
          answer={@state.answers[question.key]}
          optional={not question.blocking}
        />
        <.folded_question
          :if={not open?(@state, question)}
          form={@id}
          question={question}
          answer={@state.answers[question.key]}
        />
      </div>

      <p :if={@left > 0} class="text-sm/[1.55] opacity-70" id={"form-#{@id}-left"}>
        {@left} {@kind}{if @left == 1, do: "question", else: "questions"} left
      </p>

      <button
        type="submit"
        disabled={@left > 0 or @locked == 0}
        phx-disable-with="Sending…"
        class="h-12 w-full rounded-field bg-base-content px-4 text-sm font-medium text-base-100 disabled:opacity-40"
      >
        Send {@locked} {if @locked == 1, do: "answer", else: "answers"}
      </button>
    </form>
    """
  end

  attr :form, :string, required: true
  attr :question, :map, required: true
  attr :answer, :map, required: true
  attr :optional, :boolean, required: true

  defp open_question(assigns) do
    ~H"""
    <div role="group" aria-label={@question.text} class="flex flex-col gap-[11px]">
      <%!-- Not accent: accent is spent on what waits (`docs/design/ui.md` § Colour), and the
            passage a question is about is context, drawn beside an assumption too. --%>
      <blockquote
        :if={@question.anchor}
        class="border-l-2 border-base-content/30 bg-base-200 py-1 pl-3 text-sm/[1.55] opacity-80"
      >
        {@question.anchor}
      </blockquote>

      <p class="flex items-baseline justify-between gap-3">
        <span class="text-sm/[1.55] font-medium">{@question.text}</span>
        <span
          :if={@optional}
          class="shrink-0 font-mono text-[11px] tracking-[.14em] uppercase opacity-50"
        >
          optional
        </span>
      </p>

      <p :if={@question.assumption} class="text-[12.5px]/[1.5] opacity-70">
        Assumed: {@question.assumption}
      </p>

      <div :if={@question.options != []} class="flex flex-col gap-2">
        <label
          :for={option <- @question.options}
          class={[
            "flex min-h-[52px] cursor-pointer items-start gap-3 rounded-field border px-4 py-3",
            if(@answer["choice"] == option.label,
              do: "border-primary bg-base-200",
              else: "border-base-300 hover:border-base-content/30"
            )
          ]}
        >
          <input
            type="radio"
            name={"answers[#{@question.key}][choice]"}
            value={option.label}
            checked={@answer["choice"] == option.label}
            class="radio radio-sm radio-primary mt-0.5 shrink-0"
          />
          <span class="flex min-w-0 flex-col gap-0.5">
            <span class="flex flex-wrap items-baseline gap-x-2">
              <span class="text-sm font-medium">{option.label}</span>
              <span
                :if={option.recommended}
                class="rounded-selector border border-base-content/30 px-1 font-mono text-[11px] tracking-[.14em] uppercase opacity-60"
              >
                recommended
              </span>
            </span>
            <span :if={option.detail} class="text-[13px]/[1.45] opacity-70">{option.detail}</span>
          </span>
        </label>

        <%!-- A radio of its own, so clearing is part of the form's state like choosing is. Without
              it a recommendation that started chosen could never become an answer in your own
              words. --%>
        <label
          :if={@answer["choice"]}
          class="flex min-h-[46px] cursor-pointer items-center self-start text-sm text-primary hover:underline"
        >
          <input
            type="radio"
            name={"answers[#{@question.key}][choice]"}
            value=""
            class="sr-only"
          /> Clear choice
        </label>
      </div>

      <input
        type="text"
        name={"answers[#{@question.key}][text]"}
        value={@answer["text"]}
        phx-debounce="300"
        aria-label={"Your own words on: #{@question.text}"}
        placeholder={
          if @question.options == [],
            do: "answer in your own words",
            else: "add a note, or answer in your own words"
        }
        class="h-12 w-full rounded-field border border-base-300 bg-transparent px-3 text-sm placeholder:opacity-40 focus:outline-none focus:border-base-content/40"
      />
    </div>
    """
  end

  attr :form, :string, required: true
  attr :question, :map, required: true
  attr :answer, :map, required: true

  # Folded, the answer still rides the form: every change and the Send carry the whole draft.
  defp folded_question(assigns) do
    ~H"""
    <input
      type="hidden"
      name={"answers[#{@question.key}][choice]"}
      value={@answer["choice"] || ""}
    />
    <input type="hidden" name={"answers[#{@question.key}][text]"} value={@answer["text"] || ""} />
    <button
      type="button"
      phx-click="form:open"
      phx-value-form={@form}
      phx-value-key={@question.key}
      class="flex min-h-[52px] w-full items-center gap-3 rounded-field border border-base-300 px-4 py-2 text-left hover:border-base-content/30"
    >
      <span aria-hidden="true" class="opacity-60">✓</span>
      <span class="flex min-w-0 flex-1 flex-col">
        <span class="truncate text-[12.5px] opacity-70">{@question.text}</span>
        <span class="truncate text-sm font-medium">{summary(@answer)}</span>
      </span>
      <span class="shrink-0 text-[12.5px] text-primary">change</span>
    </button>
    """
  end

  defp summary(answer) do
    Answer.reads(answer["choice"], answer["text"])
  end

  @doc """
  Splits `assumed` into those asked in the same document as one of `blocking` — which are answered
  in that document's form, optional — and those asked on their own: `{joined, alone}`. `version`
  reads an item's artifact version id, so the queue's items and a ticket's questions are split by
  the one rule (`docs/design/ui.md` § Answering questions).
  """
  def join_assumed(blocking, assumed, version \\ & &1.artifact_version_id) do
    held = MapSet.new(blocking, version)
    Enum.split_with(assumed, &MapSet.member?(held, version.(&1)))
  end

  # -- state -----------------------------------------------------------------------------------

  @doc """
  A form's draft: `answers` by key, each `%{"choice" => label | nil, "text" => text | nil}`,
  and the keys opened by hand. Untouched, a form's answers are its recommendations.
  """
  def state(forms, id, questions) do
    form = Map.get(forms, id, %{})

    %{
      answers: Map.get(form, :answers) || recommendations(questions),
      open: Map.get(form, :open, MapSet.new())
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

  # Open while nothing is locked in, or while opened by hand: a locked question folds so the form
  # stays short on a phone, and tapping its line brings it back.
  defp open?(state, question),
    do: not locked?(state.answers[question.key]) or MapSet.member?(state.open, question.key)

  # -- events ----------------------------------------------------------------------------------

  @doc """
  Handles a form event. `{:state, socket}` for a change to the draft, which needs no reload;
  `{:handled, socket}` for a Send, after which the page reloads; `:unknown` for anything else,
  a malformed event included.

  Everything here arrives off the wire — ids, answers, the reply a form was drawn for — so a
  payload of the wrong shape is ignored rather than raised on, and an id naming nothing is said
  in a flash. Every write goes through `Forge.Operator`, which checks membership.
  """
  def handle(event, params, socket) do
    dispatch(event, params, socket)
  rescue
    Ecto.NoResultsError -> {:handled, put_flash(socket, :error, "That no longer exists.")}
  end

  # A change naming no form is dropped by the pattern. Dropping it is an equivalent mutant rather
  # than a guard: stored, it would sit under an id no form is drawn with.
  defp dispatch("form:change", %{"form" => id} = params, socket) do
    answers = params |> answers_of() |> Map.new(fn {key, a} -> {key, answer(a)} end)
    form = Map.get(forms(socket), id, %{})
    open = Map.get(form, :open, MapSet.new())

    # Choosing folds the question; typing keeps it open, so it does not move under the thumb —
    # and so does clearing a choice, which leaves a question open to be answered in words.
    open =
      case params["_target"] do
        ["answers", key, "choice"] ->
          if answers[key]["choice"], do: MapSet.delete(open, key), else: MapSet.put(open, key)

        ["answers", key, "text"] ->
          MapSet.put(open, key)

        _other ->
          open
      end

    {:state, put_form(socket, id, %{answers: answers, open: open})}
  end

  defp dispatch("form:open", %{"form" => id, "key" => key}, socket) do
    form = Map.get(forms(socket), id, %{})
    open = form |> Map.get(:open, MapSet.new()) |> MapSet.put(key)
    {:state, put_form(socket, id, Map.put(form, :open, open))}
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
        {:handled, refused(socket, reason)}
    end
  end

  defp dispatch("chat:questions:send", %{"form" => id, "chat" => chat_id} = params, socket) do
    chat = Actions.row!(chat_id, &Conversations.get!/1, Forge.Jobs.Job)

    # Forgetting here is housekeeping, an equivalent mutant: once the answer is sent the last
    # thing said is the person's, so no form is drawn for that reply again.
    case Operator.answer_chat(chat, Actions.user(socket), params["reply"], sent(params)) do
      {:ok, _event} -> {:handled, forget(socket, id)}
      {:error, reason} -> {:handled, refused(socket, reason)}
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
  defp refused(socket, :stale) do
    put_flash(
      socket,
      :error,
      "Some of these questions were answered or changed since the page showed them. " <>
        "Nothing was sent; check what is still asked and send again."
    )
  end

  defp refused(socket, :not_live),
    do: put_flash(socket, :error, "This conversation has stopped. Reopen it to answer.")

  defp refused(socket, reason), do: put_flash(socket, :error, "Not sent: #{why(reason)}")

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
