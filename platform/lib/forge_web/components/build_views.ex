defmodule ForgeWeb.BuildViews do
  @moduledoc """
  What the pages draw of a ticket's warm builds and of a command's run on a machine
  (`docs/design/ui.md` § The details, § The job page, § The explorer; ticket 84): the rows of the
  details' warm-build block, a command's steps, its log with the time of each line, and the
  addresses and words the explorer shares with its download.

  Every name, path and line here is somebody's: it is drawn as text through the template, bytes
  that are not valid text are replaced (`shown/1`), and it breaks at any character rather than
  widening a phone's page. Nothing here asks a machine anything: `ForgeWeb.ExploreLive` does.
  """

  use ForgeWeb, :html

  alias ForgeCore.CommandSteps
  alias ForgeWeb.{Blob, Format, WorkScreen}

  # How long a silence between two lines of output is before the page marks it.
  @silence_ms 10_000

  # -- words and numbers --------------------------------------------------------------------

  @doc "A machine as the pages name it: the first eight of its id."
  @spec machine(%{id: String.t()} | String.t() | nil) :: String.t()
  def machine(nil), do: "a machine"
  def machine(%{id: id}), do: machine(id)
  def machine(id) when is_binary(id), do: "machine " <> String.slice(id, 0, 8)

  @doc """
  Text for a name, a path or a link target: what is not valid UTF-8 is replaced, and NUL is shown
  as the replacement character too, so what reaches the template is always text.
  """
  @spec shown(term()) :: String.t()
  def shown(bytes) when is_binary(bytes) do
    bytes |> String.replace_invalid() |> String.replace(<<0>>, "�")
  end

  def shown(nil), do: ""

  @doc "A duration in milliseconds as a person reads it: `40 ms`, `1.2 s`, `3 min 4 s`."
  @spec ms_label(non_neg_integer()) :: String.t()
  def ms_label(ms) when ms < 1_000, do: "#{ms} ms"
  def ms_label(ms) when ms < 60_000, do: "#{trim(ms / 1_000)} s"
  def ms_label(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)} min #{rem(div(ms, 1_000), 60)} s"

  def ms_label(ms),
    do: "#{div(ms, 3_600_000)} h #{rem(div(ms, 60_000), 60)} min"

  @doc "The time since the command started, in the narrow column: `12.3 s`, `2:05`, `1:02:05`."
  @spec since(non_neg_integer()) :: String.t()
  def since(ms) when ms < 60_000, do: "#{trim(ms / 1_000)} s"

  def since(ms) when ms < 3_600_000,
    do: "#{div(ms, 60_000)}:#{pad(rem(div(ms, 1_000), 60))}"

  def since(ms),
    do: "#{div(ms, 3_600_000)}:#{pad(rem(div(ms, 60_000), 60))}:#{pad(rem(div(ms, 1_000), 60))}"

  @doc "A silence as it is marked between two lines: `+42 s`, `+3 min 20 s`."
  @spec silence(non_neg_integer()) :: String.t()
  def silence(gap) when gap < 120_000, do: "+#{div(gap, 1_000)} s"
  def silence(gap), do: "+" <> ms_label(div(gap, 1_000) * 1_000)

  @doc """
  A size in the binary units a truncated file's sentence uses (*showing the first 1 MiB of
  40 MiB*): `812 B`, `3 KiB`, `1 MiB`, `2.3 GiB`. **The only place the explorer does not use
  `Blob.size_label/1`** (`1 MB`): the sentence's wording is the refinement's (criterion 15), and
  the limit it names is 1,048,576 bytes exactly, which `Blob.size_label/1`'s *MB* (it divides by
  1,048,576 and says MB) would misname.
  """
  @spec iec(non_neg_integer()) :: String.t()
  def iec(n) when n < 1_024, do: "#{n} B"
  def iec(n) when n < 1_048_576, do: "#{trim(n / 1_024)} KiB"
  def iec(n) when n < 1_073_741_824, do: "#{trim(n / 1_048_576)} MiB"
  def iec(n), do: "#{trim(n / 1_073_741_824)} GiB"

  defp trim(float) do
    rounded = Float.round(float * 1.0, 1)

    if rounded == trunc(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: Float.to_string(rounded)
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "A unix time (seconds) as the explorer says it: `2026-11-26 14:32` in UTC."
  @spec stamp(integer() | nil) :: String.t()
  def stamp(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, at} -> Calendar.strftime(at, "%Y-%m-%d %H:%M")
      {:error, _out_of_range} -> "—"
    end
  end

  def stamp(_none), do: "—"

  # -- addresses ----------------------------------------------------------------------------

  @doc """
  The query a path travels in. A path that is text goes as `path=…`; one that is not valid UTF-8
  cannot cross a query string (Plug refuses it), so it goes as `path64=…`, URL-safe base64 with no
  padding. The root is no query at all.
  """
  @spec path_query(binary(), keyword()) :: keyword()
  def path_query(path, extra \\ [])
  def path_query("", extra), do: extra

  def path_query(path, extra) do
    if String.valid?(path),
      do: [path: path] ++ extra,
      else: [path64: Base.url_encode64(path, padding: false)] ++ extra
  end

  @doc "The path a request names, from its params: `path` or `path64`; nil when it names a bad one."
  @spec path_param(map()) :: binary() | nil
  def path_param(%{"path64" => encoded}) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, path} -> path
      :error -> nil
    end
  end

  def path_param(%{"path" => path}) when is_binary(path), do: path
  def path_param(%{"path" => _not_text}), do: nil
  def path_param(_params), do: ""

  @doc "The explorer's address for a folder or a file of a copy."
  @spec explore_path(map(), map(), String.t(), binary(), keyword()) :: String.t()
  def explore_path(project, ticket, job_id, path, extra \\ []) do
    base = ~p"/tickets/#{project.name}/#{ticket.number}/builds/#{job_id}"
    with_query(base, path_query(path, extra))
  end

  @doc "The download's address for the whole copy (`\"\"`), a folder or a file."
  @spec download_path(map(), map(), String.t(), binary()) :: String.t()
  def download_path(project, ticket, job_id, path) do
    base = ~p"/tickets/#{project.name}/#{ticket.number}/builds/#{job_id}/download"
    with_query(base, path_query(path))
  end

  defp with_query(base, []), do: base
  defp with_query(base, query), do: base <> "?" <> URI.encode_query(query)

  @doc "The parent of a path: that of `a/b` is `a`, and that of `a` is the root."
  @spec parent(binary()) :: binary()
  def parent(path) do
    case :binary.split(path, "/", [:global]) do
      [_only] -> ""
      parts -> parts |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  # -- the details' block -------------------------------------------------------------------

  @doc """
  One kept copy as the details' block draws it. `copy` is what `Forge.WarmBuilds.copies/1` returns
  for one machine; the command is read from its job's spec, and the machine is named as a command's
  page names it.
  """
  @spec copy_row(map()) :: map()
  def copy_row(%{job: job, worker: worker} = copy) do
    command = Forge.Jobs.spec(job).command || %{}

    %{
      id: job.id,
      machine: machine(worker),
      command: command["name"],
      args: command["args"],
      commit: ForgeWeb.Diff.short(command["at"]),
      size: copy[:size],
      at: copy[:kept_at],
      next: copy[:next?] == true,
      cleared: copy[:cleared?] == true
    }
  end

  # -- a command's steps --------------------------------------------------------------------

  attr :steps, :any, required: true, doc: "`Forge.Jobs.command_steps/1`'s answer"
  attr :worker_id, :string, default: nil

  @doc """
  A command's steps in order, each with its duration, the longest emphasised and the time none of
  them covers as *other*, so they add up to the command's time on the machine
  (`docs/design/ui.md` § The job page). A step that did not happen says why and has no duration;
  a command without step events says why, and never draws a zero.
  """
  def steps(%{steps: {:unrecorded, why}} = assigns) do
    assigns = assign(assigns, :sentence, unrecorded(why, assigns.worker_id))

    ~H"""
    <section id="job-steps" class="job-steps" aria-label="Steps">
      <.eyebrow>Steps</.eyebrow>
      <p id="job-steps-unrecorded" class="job-none break-words">{@sentence}</p>
    </section>
    """
  end

  def steps(%{steps: {:steps, steps}} = assigns) do
    total = CommandSteps.total(steps)

    assigns =
      assign(assigns,
        list: steps,
        longest: CommandSteps.longest(steps),
        total: total
      )

    ~H"""
    <section id="job-steps" class="job-steps" aria-label="Steps">
      <.eyebrow>Steps</.eyebrow>
      <ol class="job-step-list">
        <li
          :for={step <- @list}
          id={"job-step-#{step["name"]}"}
          class={["job-step", step["name"] == @longest && "job-step--longest"]}
          data-longest={step["name"] == @longest && "true"}
        >
          <span class="job-step-name min-w-0 break-words">
            {CommandSteps.label(step["name"])}<span :if={step["source"]} class="job-dim"> · from {ForgeCore.WarmBuild.source_phrase(
              step["source"]
            )}</span>
          </span>
          <span :if={step["skipped"]} class="job-step-time job-step-time--skipped job-dim">
            {CommandSteps.skip_sentence(step["skipped"])}
          </span>
          <span :if={!step["skipped"]} class="job-step-time">
            {ms_label(step["ms"] || 0)}<span :if={step["name"] == @longest} class="job-dim"> · longest</span>
          </span>
          <span
            :if={!step["skipped"] && @total > 0}
            class="job-step-bar"
            style={"width: #{max(div((step["ms"] || 0) * 100, @total), 1)}%"}
            aria-hidden="true"
          ></span>
        </li>
      </ol>
      <p id="job-steps-total" class="job-none">on the machine: {ms_label(@total)}</p>
    </section>
    """
  end

  def steps(%{steps: :running} = assigns) do
    ~H"""
    <section id="job-steps" class="job-steps" aria-label="Steps">
      <.eyebrow>Steps</.eyebrow>
      <p id="job-steps-pending" class="job-none">Recorded when the command ends.</p>
    </section>
    """
  end

  def steps(assigns), do: ~H""

  defp unrecorded(:release, worker_id),
    do: "not recorded: #{machine(worker_id)}'s release predates step timings"

  defp unrecorded(_before, _worker_id), do: "not recorded: it ran before forge recorded steps"

  # -- a command's log ----------------------------------------------------------------------

  @doc """
  The rows of a log: each line with its time since the command started, the minute it opens
  (for a phone's divider, said once a minute as the job stream does), and the silence before it
  when that is ten seconds or more. A line with no time, from a log stored before times were
  kept, has none of the three.
  """
  @spec log_rows([{non_neg_integer() | nil, binary()}], non_neg_integer()) :: [map()]
  def log_rows(lines, first \\ 0) do
    lines
    |> Enum.with_index(first)
    |> Enum.map_reduce({nil, nil}, fn {{ms, text}, n}, {previous_ms, previous_minute} ->
      minute = ms && div(ms, 60_000)

      row = %{
        n: n,
        ms: ms,
        text: text,
        minute: if(minute && minute != previous_minute, do: "+#{minute} min"),
        silence: if(ms && previous_ms && ms - previous_ms >= @silence_ms, do: ms - previous_ms)
      }

      {row, {ms || previous_ms, minute || previous_minute}}
    end)
    |> elem(0)
  end

  @doc "The gap the page marks, in milliseconds."
  @spec silence_ms() :: pos_integer()
  def silence_ms, do: @silence_ms

  attr :log, :map, default: nil, doc: "`Forge.Jobs.command_log/2`'s answer"
  attr :job, :map, required: true

  @doc """
  The output of a command, newest at the bottom, in a pane that follows it while it runs. The log
  file itself carries no times (`docs/design/commands.md`): they are drawn from the lines the
  worker streamed, and after the command ends from the times kept beside the log.
  """
  def command_log(%{log: nil} = assigns), do: ~H""

  def command_log(assigns) do
    rows = log_rows(assigns.log.lines, assigns.log.shown_from)
    shown_from = assigns.log.shown_from
    assigns = assign(assigns, rows: rows, earlier: shown_from)

    ~H"""
    <section id="job-output" class="job-output" aria-label="Output">
      <.eyebrow>Output</.eyebrow>
      <p id="job-output-head" class="job-none">
        {Format.counted(@log.total, "line")}{if @log.source == :live, do: " · live", else: ""}
      </p>
      <p
        :if={@log.source == :live and Map.get(@log, :held_from, 0) > 0}
        id="job-output-capped"
        class="job-none"
      >
        The earliest {@log.held_from} lines are not held while it runs; they are in the log once it ends.
      </p>
      <p :if={@rows == []} id="job-output-empty" class="job-none">
        {if @job.status == :running, do: "No output yet.", else: "No output was kept."}
      </p>
      <.scroll_log :if={@rows != []} rows={@rows} earlier={@earlier} />
    </section>
    """
  end

  attr :rows, :list, required: true
  attr :earlier, :integer, required: true

  defp scroll_log(assigns) do
    ~H"""
    <ForgeWeb.Operator.Components.scroll_pane id="job-log-pane" height={nil} class="job-pane">
      <WorkScreen.load_older
        :if={@earlier > 0}
        id="job-log-earlier"
        event="log-earlier"
        class="job-earlier"
      >
        ▸ {@earlier} earlier
      </WorkScreen.load_older>
      <ol id="job-log" class="job-entries" data-scroll-items>
        <.log_row :for={row <- @rows} row={row} />
      </ol>
    </ForgeWeb.Operator.Components.scroll_pane>
    """
  end

  attr :row, :map, required: true

  # A line, and above it the silence that came before it when that is ten seconds or more.
  defp log_row(assigns) do
    ~H"""
    <li :if={@row.silence} id={"job-log-silence-#{@row.n}"} class="job-silence">
      {silence(@row.silence)}
    </li>
    <li id={"job-log-#{@row.n}"} class="job-entry" data-minute={@row.minute}>
      <span :if={@row.ms} class="job-entry-time">{since(@row.ms)}</span>
      <span class="job-entry-main job-log-text">{shown(@row.text)}</span>
    </li>
    """
  end

  # Used by the explorer: a size the way a person reads one, or nothing for one nobody knows.
  @doc false
  @spec size_or_nil(non_neg_integer() | nil) :: String.t() | nil
  def size_or_nil(nil), do: nil
  def size_or_nil(bytes), do: Blob.size_label(bytes)
end
