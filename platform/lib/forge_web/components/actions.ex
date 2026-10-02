defmodule ForgeWeb.Actions do
  @moduledoc """
  What an agent did, drawn as lines: one mono line per tool call, in info colour, unboxed
  (`docs/design/ui.md` § Talk).

  **One component for every surface that draws a call** — a conversation's transcript, a work
  screen's Activity tab and the job page — so that an edit, a command and a failure read the same
  whichever of them, and whichever kind of job, made them.

  An action here is `Forge.Conversations.action/0`: a `tool_use` paired with its `tool_result`,
  with a `Task`'s subagent calls as its children. What each call becomes:

  | Call | Line |
  |---|---|
  | `Edit`, `MultiEdit`, `Write`, `NotebookEdit` | `✎ path +n −m`, expanding to the change |
  | `Bash` | `$ command` and ✓ or ✗; a failure shows its excerpt's first lines unasked |
  | `Read`, `Grep`, `Glob`, `LS` in a row | one line for the run, expanding to the list |
  | `TodoWrite` | the plan as a checklist |
  | `Task` | `⤷ description`, its subagent's calls folded under it |
  | `WebFetch`, `WebSearch` | `↗ url`, `? query` |
  | anything else | its name and its input, as the job page's row summarises one |

  Any result with `is_error` is in error colour with its excerpt, whatever the call.

  **An opened line stays open while the list it is in is patched.** Every `<details>` here is
  marked with `keep_open/0`: the server never renders `open`, so each patch of a live transcript
  or a running job's stream used to close whatever the reader had opened — the same reason
  `ForgeWeb.Sheet` ignores `open` on its dialog.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @edits ~w(Edit MultiEdit Write NotebookEdit)
  @looks ~w(Read Grep Glob LS)

  # How much of a change or an excerpt a line shows before it says how much more there is. A line
  # is a glance; the change itself is on the Changes tab and the output in the Activity tab.
  @shown_lines 40
  @failure_lines 6

  # How much of one line of a log is drawn before the rest waits behind a control.
  @clip 200

  @type kind :: :edit | :bash | :look | :todo | :task | :fetch | :search | :other

  @doc "What kind of line a call is drawn as."
  @spec kind(map()) :: kind()
  def kind(%{name: name}) when name in @edits, do: :edit
  def kind(%{name: name}) when name in @looks, do: :look
  def kind(%{name: "Bash"}), do: :bash
  def kind(%{name: "TodoWrite"}), do: :todo
  def kind(%{name: "Task"}), do: :task
  def kind(%{name: "WebFetch"}), do: :fetch
  def kind(%{name: "WebSearch"}), do: :search
  def kind(_action), do: :other

  @doc """
  A run of calls as the lines it is drawn with: consecutive reads and searches are one line, and
  every other call is one line of its own.
  """
  @spec lines([map()]) :: [{:looks, [map()]} | {:one, map()}]
  def lines(actions) do
    actions
    |> Enum.chunk_by(&(kind(&1) == :look))
    |> Enum.flat_map(fn
      [first | _rest] = looks when first.name in @looks -> [{:looks, looks}]
      chunk -> Enum.map(chunk, &{:one, &1})
    end)
  end

  @doc """
  The one line a finished run of calls folds into:
  *11 actions · edited parser.ex, lexer.ex · mix test ✗→✓*.
  """
  @spec fold_summary([map()]) :: String.t()
  def fold_summary(actions) do
    count = length(actions)

    [
      "#{count} #{if count == 1, do: "action", else: "actions"}",
      edited(actions),
      commands(actions)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp edited(actions) do
    case actions |> Enum.filter(&(kind(&1) == :edit)) |> Enum.map(&basename/1) |> Enum.uniq() do
      [] ->
        nil

      names when length(names) > 3 ->
        "edited #{names |> Enum.take(3) |> Enum.join(", ")} +#{length(names) - 3}"

      names ->
        "edited " <> Enum.join(names, ", ")
    end
  end

  # Each distinct command with how each run of it came out, in order: `mix test ✗→✓` is the
  # agent fixing what it broke, and the arrow is what makes that readable in one glance. In the
  # order they were first run, which is the run's own order — not their times, which are to the
  # second and so the same for two commands run in one.
  defp commands(actions) do
    bash = Enum.filter(actions, &(kind(&1) == :bash))
    runs = Enum.group_by(bash, &command/1)

    bash
    |> Enum.map(&command/1)
    |> Enum.uniq()
    |> Enum.take(2)
    |> Enum.map(fn command ->
      "#{truncate(command, 40)} #{Enum.map_join(runs[command], "→", &mark/1)}"
    end)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  @doc "The calls in a run whose result was an error: what stays visible when the run is folded."
  @spec errors([map()]) :: [map()]
  def errors(actions), do: Enum.filter(actions, &error?/1)

  defp error?(%{result: %{is_error: true}}), do: true
  defp error?(_action), do: false

  @doc """
  The now line's words for what the agent is doing (`Forge.Conversations.now/1`): *running mix
  test*, *editing lexer.ex*, *retrying (2 of 10)*, *rate limited, resumes 14:00 UTC*, *a process
  was killed for memory (1 OOM kill · peak 2.0 GiB of 2 GiB)*.
  """
  @spec now_words(Forge.Conversations.now()) :: String.t() | nil
  def now_words(nil), do: nil
  def now_words({:retrying, attempt, max}), do: "retrying (#{attempt || "?"} of #{max || "?"})"
  def now_words({:rate_limited, nil}), do: "rate limited"

  def now_words({:rate_limited, %DateTime{} = at}),
    do: "rate limited, resumes #{Calendar.strftime(at, "%H:%M")} UTC"

  def now_words({:memory, payload}), do: Forge.Jobs.Memory.sentence(payload)
  def now_words({:action, action}), do: doing(kind(action), action)

  defp doing(:bash, action), do: "running " <> truncate(command(action), 60)
  defp doing(:edit, action), do: "editing " <> basename(action)
  defp doing(:look, %{name: "Read"} = action), do: "reading " <> basename(action)
  defp doing(:look, action), do: "searching " <> truncate(target(action), 60)
  defp doing(:todo, _action), do: "planning"

  defp doing(:task, action), do: "delegating: " <> truncate(task_description(action), 60)
  defp doing(:fetch, action), do: "fetching " <> truncate(field(action, "url"), 60)

  defp doing(:search, action),
    do: "searching the web for " <> truncate(field(action, "query"), 60)

  defp doing(:other, action), do: "running #{action.name}"

  @doc """
  The current item of a plan: the one in progress, else the first not done — what the plan
  above the now line is collapsed to.
  """
  @spec current_todo([map()]) :: map() | nil
  def current_todo(todos) do
    Enum.find(todos, &(&1["status"] == "in_progress")) ||
      Enum.find(todos, &(&1["status"] != "completed"))
  end

  @doc "A `TodoWrite`'s list, or `[]`."
  @spec todos(map()) :: [map()]
  def todos(%{input: %{"todos" => todos}}) when is_list(todos),
    do: Enum.filter(todos, &is_map/1)

  def todos(_action), do: []

  @doc """
  A run of calls: every line while `folded` is false; one line that expands in place when it is
  true, with any failure kept visible beneath it.

  `todo` is the plan to draw at a `TodoWrite` — the latest in the turn, so the checklist is
  redrawn in place rather than repeated — and `todo_at` is the one call it is drawn at.
  """
  attr :actions, :list, required: true
  attr :folded, :boolean, default: false
  attr :todo, :list, default: []
  attr :todo_at, :any, default: nil
  attr :id, :string, required: true

  def run(assigns) do
    assigns = assign(assigns, errors: errors(assigns.actions))

    ~H"""
    <div :if={not @folded} id={@id} class="flex flex-col py-1" data-run="live">
      <.line :for={line <- lines(@actions)} line={line} todo={@todo} todo_at={@todo_at} />
    </div>

    <div :if={@folded} id={@id} class="flex flex-col py-1" data-run="folded">
      <details class="peer" phx-mounted={keep_open()}>
        <summary class="flex min-h-[46px] cursor-pointer items-center gap-2 font-mono text-[12.5px] text-info">
          <span aria-hidden="true" class="opacity-60">▸</span>
          <span class="min-w-0 break-words">{fold_summary(@actions)}</span>
        </summary>
        <div class="flex flex-col pl-4">
          <.line :for={line <- lines(@actions)} line={line} todo={@todo} todo_at={@todo_at} />
        </div>
      </details>
      <%!-- A failure is the one thing a folded run may not hide: scrolled back through, the
            transcript is the conversation plus whatever went wrong. Beneath the fold while it is
            closed, and inside it — once — while it is open. --%>
      <div :if={@errors != []} class="flex flex-col peer-open:hidden" data-run-errors>
        <.line :for={action <- @errors} line={{:one, action}} />
      </div>
    </div>
    """
  end

  attr :line, :any, required: true
  attr :todo, :list, default: []
  attr :todo_at, :any, default: nil

  @doc "One line of a run: a call, or a run of reads and searches."
  def line(%{line: {:looks, actions}} = assigns) do
    assigns = assign(assigns, actions: actions)

    ~H"""
    <details
      class="font-mono text-[12.5px] text-info"
      data-action="look"
      phx-mounted={keep_open()}
    >
      <summary class="flex min-h-[46px] cursor-pointer items-center gap-2">
        <span class="min-w-0 break-words">{looks_summary(@actions)}</span>
        <span :if={errors(@actions) != []} class="text-error">✗</span>
      </summary>
      <ul class="flex flex-col gap-1 pb-2 pl-4 opacity-80">
        <li :for={action <- @actions} class={["break-all", error?(action) && "text-error"]}>
          {action.name} {target(action)}
        </li>
      </ul>
    </details>
    <%!-- Outside the fold: a failure's excerpt is shown without being asked for. --%>
    <.failure :for={action <- errors(@actions)} action={action} />
    """
  end

  # A read or a search on its own — the Activity tab draws calls one at a time — is the same
  # line a run of them is, so it reads the same wherever it is drawn.
  def line(%{line: {:one, %{name: name} = action}} = assigns) when name in @looks,
    do: line(%{assigns | line: {:looks, [action]}})

  def line(%{line: {:one, action}} = assigns) do
    assigns
    |> assign(action: action, kind: kind(action), error: error?(action))
    |> draw()
  end

  defp draw(%{kind: :todo} = assigns) do
    ~H"""
    <div :if={@todo_at in [nil, @action.id]} class="py-1 font-mono text-[12.5px]" data-action="todo">
      <.checklist todos={if @todo_at, do: @todo, else: todos(@action)} />
    </div>
    <.failure :if={@error} action={@action} />
    """
  end

  defp draw(%{kind: :edit} = assigns) do
    assigns = assign(assigns, counts: edit_counts(assigns.action))

    ~H"""
    <details
      class={["font-mono text-[12.5px]", (@error && "text-error") || "text-info"]}
      data-action="edit"
      phx-mounted={keep_open()}
    >
      <summary class="flex min-h-[46px] cursor-pointer items-center gap-2" title={path(@action)}>
        <span aria-hidden="true">✎</span>
        <span class="min-w-0 break-all">{short_path(path(@action))}</span>
        <span class="shrink-0 opacity-70">+{elem(@counts, 0)} −{elem(@counts, 1)}</span>
      </summary>
      <pre class="mb-2 overflow-x-auto rounded-field border border-base-300 p-2 text-base-content"><code>{edit_diff(@action)}</code></pre>
    </details>
    <.failure :if={@error} action={@action} />
    """
  end

  defp draw(%{kind: :bash} = assigns) do
    ~H"""
    <div
      class={["py-1 font-mono text-[12.5px]", (@error && "text-error") || "text-info"]}
      data-action="bash"
    >
      <.clip text={"$ " <> command(@action)} class="break-all">
        <span :if={@action.result} class="ml-1">{mark(@action)}</span>
      </.clip>
    </div>
    <.failure :if={@error} action={@action} />
    """
  end

  # A Task whose subagent's calls are not here — the Activity tab draws each call on its own
  # row — has nothing to expand to, so it is a line and not a control.
  defp draw(%{kind: :task, action: %{children: []}} = assigns) do
    ~H"""
    <div
      class={["py-1 font-mono text-[12.5px]", (@error && "text-error") || "text-info"]}
      data-action="task"
    >
      <span aria-hidden="true">⤷</span> <span class="break-words">{task_description(@action)}</span>
    </div>
    <.failure :if={@error} action={@action} />
    """
  end

  defp draw(%{kind: :task} = assigns) do
    ~H"""
    <details
      class={["font-mono text-[12.5px]", (@error && "text-error") || "text-info"]}
      data-action="task"
      phx-mounted={keep_open()}
    >
      <summary class="flex min-h-[46px] cursor-pointer items-center gap-2">
        <span aria-hidden="true">⤷</span>
        <span class="min-w-0 break-words">{task_description(@action)}</span>
        <span class="shrink-0 opacity-60">
          {length(@action.children)} {if length(@action.children) == 1, do: "call", else: "calls"}
        </span>
      </summary>
      <div class="flex flex-col pl-4">
        <.line :for={line <- lines(@action.children)} line={line} />
      </div>
    </details>
    <.failure :if={@error} action={@action} />
    """
  end

  defp draw(assigns) do
    ~H"""
    <div
      class={["py-1 font-mono text-[12.5px]", (@error && "text-error") || "text-info"]}
      data-action={@kind}
    >
      <.clip text={plain(@kind, @action)} class="break-all" />
    </div>
    <.failure :if={@error} action={@action} />
    """
  end

  attr :action, :map, required: true

  # A failure says what failed without being asked: the first lines of its excerpt, which is
  # usually the one that names the error.
  defp failure(assigns) do
    assigns = assign(assigns, shown: first_lines(assigns.action.result.excerpt, @failure_lines))

    ~H"""
    <pre
      :if={@shown != ""}
      class="mb-1 overflow-x-auto whitespace-pre-wrap break-all pl-4 font-mono text-[12px] text-error opacity-90"
      data-failure
    >{@shown}</pre>
    """
  end

  @doc """
  One line of a log that may be longer than a glance: up to #{@clip} characters as they are,
  wrapped and keeping their line breaks; past that, the first #{@clip} and a control that opens
  the whole of it in place (`docs/design/ui.md` § Activity). The whole is already in the page, so
  opening it fetches nothing and a test reads it without a click.

  The slot is drawn after the text, open or not — a command's ✓ is read at a glance.
  """
  attr :text, :string, required: true
  attr :class, :any, default: nil, doc: "for the text: how it breaks"
  slot :inner_block

  def clip(assigns) do
    assigns = assign(assigns, clipped: String.length(assigns.text) > @clip, most: @clip)

    # The text keeps its line breaks and the slot does not sit inside it: whitespace around a
    # slot is the caller's indentation, and inside `pre-wrap` it put a command's ✓ on a line of
    # its own. `phx-no-format` keeps the formatter's indentation out of the text for the same
    # reason.
    ~H"""
    <span :if={not @clipped}>
      <span class={["whitespace-pre-wrap", @class]} phx-no-format>{@text}</span>
      {render_slot(@inner_block)}
    </span>
    <details :if={@clipped} class="group" data-clipped phx-mounted={keep_open()}>
      <summary class="flex min-h-[46px] cursor-pointer list-none flex-col justify-center gap-0.5 [&::-webkit-details-marker]:hidden">
        <span class="group-open:hidden">
          <span class={["whitespace-pre-wrap", @class]} phx-no-format>{String.slice(@text, 0, @most)}…</span>
          {render_slot(@inner_block)}
        </span>
        <span class="text-primary">
          <span class="group-open:hidden">show all {String.length(@text)} characters</span>
          <span class="hidden group-open:inline">show less</span>
        </span>
      </summary>
      <span class={["whitespace-pre-wrap", @class]} phx-no-format>{@text}</span>
      {render_slot(@inner_block)}
    </details>
    """
  end

  @doc """
  What every `<details>` that LiveView patches carries: `open` is the reader's, not the server's,
  so a patch leaves it as the reader left it (`ForgeWeb.Sheet` does the same for its dialog).
  """
  @spec keep_open() :: JS.t()
  def keep_open, do: JS.ignore_attributes(["open"])

  attr :todos, :list, required: true

  @doc "A plan as a checklist: done, in progress, not started."
  def checklist(assigns) do
    ~H"""
    <ul class="flex flex-col gap-0.5 text-info">
      <li :for={todo <- @todos} class={["flex gap-2", todo["status"] == "completed" && "opacity-50"]}>
        <span aria-hidden="true" class="shrink-0">{todo_mark(todo["status"])}</span>
        <span class="min-w-0 break-words font-sans text-sm/[1.4]">{todo_text(todo)}</span>
      </li>
    </ul>
    """
  end

  defp todo_mark("completed"), do: "☑"
  defp todo_mark("in_progress"), do: "▸"
  defp todo_mark(_pending), do: "☐"

  @doc "What a plan item says: while it is in progress, its present-tense form if it has one."
  @spec todo_text(map()) :: String.t()
  def todo_text(%{"status" => "in_progress", "activeForm" => active}) when is_binary(active),
    do: active

  def todo_text(%{"content" => content}) when is_binary(content), do: content
  def todo_text(_todo), do: ""

  defp plain(:fetch, action), do: "↗ " <> field(action, "url")
  defp plain(:search, action), do: "? " <> field(action, "query")

  # A call it has no line for reads as the event log reads it: its name and its input, bounded.
  defp plain(_other, action), do: Forge.Events.tool_summary(action.name, action.input)

  defp task_description(action) do
    case field(action, "description") do
      "" -> "a task"
      description -> description
    end
  end

  defp looks_summary(actions) do
    {reads, searches} = Enum.split_with(actions, &(&1.name in ["Read", "LS"]))

    [
      reads != [] && "read #{length(reads)} #{if length(reads) == 1, do: "file", else: "files"}",
      searches != [] && "searched #{length(searches)}×"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp mark(%{result: %{is_error: true}}), do: "✗"
  defp mark(%{result: %{}}), do: "✓"
  defp mark(_pending), do: "…"

  defp command(action),
    do: action |> field("command") |> String.split("\n", parts: 2) |> hd() |> String.trim()

  defp target(%{name: "Read"} = action), do: path(action)
  defp target(%{name: "LS"} = action), do: field(action, "path")
  defp target(action), do: first_field(action, ["pattern", "path"])

  defp path(action), do: first_field(action, ["file_path", "notebook_path", "path"])

  # The agent wrote the input, and a model sometimes sends a field in the wrong type — a list
  # where the schema says a string. The harness refuses the call, but it stays in the log for
  # ever, so a line reads each field as text or not at all rather than raising on every mount.
  defp field(action, key) do
    case action.input[key] do
      text when is_binary(text) -> text
      _missing_or_not_text -> ""
    end
  end

  defp first_field(action, keys) do
    Enum.find_value(keys, "", fn key ->
      case field(action, key) do
        "" -> nil
        text -> text
      end
    end)
  end

  defp edits(%{input: %{"edits" => edits}}) when is_list(edits), do: Enum.filter(edits, &is_map/1)
  defp edits(_action), do: []

  defp basename(action), do: action |> path() |> Path.basename()

  @doc """
  A path short enough for one line on a phone: its last three segments. The agent works in a
  checkout whose absolute path is the worker's, not the repository's, and the segments nearest
  the file are the ones that say which file it is.
  """
  @spec short_path(String.t()) :: String.t()
  def short_path(path) do
    case String.split(path, "/", trim: true) do
      segments when length(segments) > 3 -> "…/" <> (segments |> Enum.take(-3) |> Enum.join("/"))
      _short -> path
    end
  end

  @doc "Lines added and removed by an edit call, from its input."
  @spec edit_counts(map()) :: {non_neg_integer(), non_neg_integer()}
  def edit_counts(%{name: "Edit", input: input}),
    do: {count_lines(input["new_string"]), count_lines(input["old_string"])}

  def edit_counts(%{name: "MultiEdit"} = action) do
    action
    |> edits()
    |> Enum.reduce({0, 0}, fn edit, {added, removed} ->
      {added + count_lines(edit["new_string"]), removed + count_lines(edit["old_string"])}
    end)
  end

  def edit_counts(%{name: "Write", input: input}), do: {count_lines(input["content"]), 0}
  def edit_counts(%{input: input}), do: {count_lines(input["new_source"]), 0}

  defp edit_diff(%{name: "MultiEdit"} = action) do
    action
    |> edits()
    |> Enum.map_join("\n", &pair_diff(&1["old_string"], &1["new_string"]))
    |> bounded()
  end

  defp edit_diff(%{name: "Edit", input: input}),
    do: pair_diff(input["old_string"], input["new_string"]) |> bounded()

  defp edit_diff(%{name: "Write", input: input}),
    do: pair_diff(nil, input["content"]) |> bounded()

  defp edit_diff(%{input: input}), do: pair_diff(nil, input["new_source"]) |> bounded()

  defp pair_diff(old, new),
    do: Enum.join(prefixed(old, "−") ++ prefixed(new, "+"), "\n")

  defp prefixed(text, _sign) when text in [nil, ""], do: []

  defp prefixed(text, sign) when is_binary(text),
    do: text |> String.trim_trailing("\n") |> String.split("\n") |> Enum.map(&(sign <> " " <> &1))

  defp prefixed(_other, _sign), do: []

  defp bounded(text) do
    lines = String.split(text, "\n")

    if length(lines) > @shown_lines do
      Enum.join(Enum.take(lines, @shown_lines), "\n") <>
        "\n… #{length(lines) - @shown_lines} more lines"
    else
      text
    end
  end

  defp count_lines(text) when text in [nil, ""], do: 0

  defp count_lines(text) when is_binary(text),
    do: text |> String.trim_trailing("\n") |> String.split("\n") |> length()

  defp count_lines(_other), do: 0

  defp first_lines(text, count),
    do:
      text |> String.split("\n") |> Enum.take(count) |> Enum.join("\n") |> String.trim_trailing()

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
