defmodule ForgeWeb.WorkerUpdate do
  @moduledoc """
  What the machines view says about a permanent machine's update and its disk
  (`docs/design/ui.md` § The machines view, `docs/design/worker-tier.md` § Updating a permanent
  machine): the one update line in words, the switch, *Update now* with its confirm, the words that
  end the lines that used to say *update it*, and the disk breakdown under the disk meter.

  **Everything a machine said is text, drawn escaped, and only text.** What it sent is cleaned
  twice before it is kept (`ForgeCore.WorkerUpdate`, `Forge.Workers.Updates`), and a value of the
  wrong type is left out *here* too rather than raised on: the row is read by every later mount of
  the page, and one malformed value once took it down for good (`ForgeWeb.WorkersLive.harness_text/1`).
  Each line is clipped to one row with the whole of it in `title`.

  **Only the owner's pages draw any of it**, and each write reads the machine scoped to the
  viewer first (`Forge.Workers.Updates`). The version named is the release's (*0.23.0*), never a
  build hash.
  """

  use ForgeWeb, :html

  alias Forge.WorkerImage
  alias Forge.Workers.Updates
  alias ForgeCore.WorkerUpdate
  alias ForgeWeb.Format

  @type line :: %{tone: :neutral | :warning | :danger, text: String.t()}

  # -- the update line --------------------------------------------------------------------------

  @doc """
  The one line about an update, or nil: drawn **whenever the machine's build is not the platform's
  or an update is under way**, for a permanent machine of a node that has a release, in steps and
  never percentages.
  """
  @spec line(map(), boolean(), DateTime.t()) :: line() | nil
  def line(worker, connected, now \\ DateTime.utc_now()) do
    release = WorkerImage.release()
    if drawn?(worker, release), do: describe(worker, connected, release, now)
  end

  defp drawn?(_worker, nil), do: false

  defp drawn?(worker, _release),
    do: Updates.permanent?(worker) and worker.status != :destroyed and not is_nil(worker.protocol)

  defp describe(worker, connected, release, now) do
    state = state(worker)
    step = step(state)
    version = version(state, release)

    cond do
      step in Updates.under_way() -> progress(step, state, version)
      worker.build != release.build -> differing(step, state, worker, connected, version, now)
      true -> nil
    end
  end

  # What a machine on another build than the platform's has to say: how its last try ended, why it
  # cannot try, or that one is waiting.
  defp differing(step, state, worker, _connected, version, now)
       when step in ["failed", "gave_up"],
       do: failed(state, worker, version, now)

  defp differing("fell_back", state, worker, _connected, version, now),
    do: fell_back(state, worker, version, now)

  defp differing(_step, _state, worker, connected, version, _now) do
    case Updates.unable(worker) do
      nil -> waiting(worker, connected, version)
      code -> %{tone: :warning, text: "cannot update itself: " <> why(code, worker)}
    end
  end

  defp state(%{update_state: %{} = state}), do: state
  defp state(_worker), do: %{}

  defp step(state), do: text(state["step"])

  defp version(state, release), do: text(state["target_version"]) || release.version

  defp progress("pausing", state, version) do
    jobs = count(state["jobs"])
    chats = count(state["chats"])

    detail =
      if jobs && chats do
        ": #{jobs} #{plural(jobs, "job")} paused, #{chats} #{plural(chats, "chat")} " <>
          "#{if chats == 1, do: "ends", else: "end"} after its turn"
      else
        ""
      end

    %{tone: :neutral, text: "updating to #{version}: pausing" <> detail}
  end

  defp progress("trying", _state, version),
    do: %{tone: :neutral, text: "trying #{version}: kept once the platform accepts it"}

  defp progress(step, _state, version),
    do: %{tone: :neutral, text: "updating to #{version}: #{step}"}

  defp failed(state, worker, version, now) do
    gave_up = step(state) == "gave_up" or is_nil(state["next_at"])

    %{
      tone: :danger,
      text:
        "update to #{version} failed while #{failed_step(state)}: #{reason(state)}" <>
          retry(state, gave_up, worker, now)
    }
  end

  defp fell_back(state, worker, version, now) do
    old = old_version(worker)

    what =
      if (text(state["reason"]) || "") =~ "did not come up",
        do: "#{version} did not come up",
        else: "#{version} was not accepted within #{div(WorkerUpdate.trial_ms(), 60_000)} minutes"

    %{
      tone: :danger,
      text: "#{what}; back on #{old}" <> retry(state, is_nil(state["next_at"]), worker, now)
    }
  end

  defp retry(_state, true, _worker, _now), do: ": stopped after #{WorkerUpdate.tries()} tries"

  defp retry(state, false, _worker, _now) do
    case time_of(state["next_at"]) do
      nil ->
        ""

      at ->
        ": tries again at #{Calendar.strftime(at, "%H:%M UTC")} (#{attempt(state)} of #{WorkerUpdate.tries()})"
    end
  end

  defp attempt(state), do: count(state["attempt"]) || 2

  # A time a machine named, as a `DateTime`, or nothing: a number past the year 9999 is a number
  # and not a time, and `from_unix!` on it would raise on every mount of the page. A negative one is not a time
  # either: `Updates` dates a cleanup by how long before the report it ran, so a machine that says
  # the report was made long after the cleanup would put it before 1970.
  defp time_of(value) do
    with at when is_integer(at) and at >= 0 <- value,
         {:ok, time} <- DateTime.from_unix(at, :millisecond) do
      time
    else
      _not_a_time -> nil
    end
  end

  defp failed_step(state), do: text(state["failed_step"]) || "updating"

  defp reason(state), do: text(state["reason"]) || "no reason given"

  defp old_version(%{release: release}) when is_binary(release),
    do: release |> String.split(" ", parts: 2) |> hd()

  defp old_version(_worker), do: "its old release"

  defp waiting(%{auto_update: false}, _connected, version),
    do: %{tone: :neutral, text: "update to #{version} waiting: automatic updates are off"}

  defp waiting(_worker, true, version),
    do: %{tone: :neutral, text: "update to #{version} waiting: it starts shortly"}

  defp waiting(_worker, false, version),
    do: %{tone: :neutral, text: "update to #{version} waiting: it updates when it next connects"}

  # Why it cannot, in the owner's words. Every one ends where the owner can act.
  defp why("layout", _worker),
    do: "its boot partition holds one system; reinstall it once from the current image"

  defp why("not_an_image", _worker), do: "this worker does not run on the forge image"

  defp why("protocol", %{protocol: protocol}),
    do:
      "it speaks protocol #{protocol} and updating itself needs #{Updates.protocol()}; " <>
        "reinstall it once from the current image"

  defp why(_other, _worker), do: "reinstall it once from the current image"

  # -- the words that end an "update it" line ---------------------------------------------------

  @doc """
  How a line that told the owner to *update it* ends on a permanent machine, from one definition
  so the refusal line and the *takes no job* lines cannot differ (`docs/design/ui.md` § The
  machines view). A managed machine is replaced rather than updated, so it keeps *update it*; so
  does a node with no release, which has nothing to update to.
  """
  @spec ending(map(), boolean()) :: String.t()
  def ending(worker, connected) do
    cond do
      not Updates.permanent?(worker) or is_nil(WorkerImage.release()) ->
        "update it"

      code = Updates.unable(worker) ->
        why(code, worker)
        |> String.split("; ", parts: 2)
        |> List.last()

      worker.auto_update ->
        "it is updating itself"

      connected and Updates.update_now?(worker, true) ->
        "press Update now"

      true ->
        "turn on automatic updates and it updates when it next connects"
    end
  end

  @doc """
  What *Update now* asks before it happens: one definition, so the sentence the confirm shows
  cannot drift from what the button does (`docs/design/ui.md` § The machines view).
  """
  @spec update_confirm(non_neg_integer(), non_neg_integer()) :: String.t()
  def update_confirm(jobs, chats) do
    "Update this machine now? It pauses its #{jobs} running #{plural(jobs, "job")}, which " <>
      "resume afterwards, ends #{chats} #{plural(chats, "conversation")} after " <>
      "#{if chats == 1, do: "its", else: "their"} current turn, and restarts the machine."
  end

  # -- the disk breakdown -----------------------------------------------------------------------

  @kinds [
    {"nix_store", "Nix store"},
    {"volumes", "ticket volumes"},
    {"seeds", "seeds"},
    {"jobs", "job directories"},
    {"rest", "the rest"}
  ]

  @rules [
    {"nix_store", "Nix store collected"},
    {"volumes", "ticket volumes swept"},
    {"seeds", "superseded seeds removed"},
    {"jobs", "job directories swept"}
  ]

  @doc """
  The disk breakdown, as lines of words, or `{:note, words}` for what there is none of:
  *not measured yet* before the first report, *no breakdown: update it* from a release that sends
  none. Drawn while the machine is away, with its age: it says what was there when measured, not
  what is happening now.
  """
  @spec breakdown(map(), DateTime.t()) :: {:note, String.t()} | {:ok, map()}
  def breakdown(%{disk_report: %{"kinds" => kinds} = report} = worker, now) when is_map(kinds) do
    {:ok,
     %{
       sizes: for({key, label} <- @kinds, bytes = count(kinds[key]), do: {label, size(bytes)}),
       cleanups: cleanups(report["cleanups"], now),
       measured: measured(worker, now)
     }}
  end

  def breakdown(%{protocol: protocol}, _now) when is_integer(protocol) and protocol >= 13,
    do: {:note, "not measured yet"}

  def breakdown(%{protocol: protocol}, _now) when is_integer(protocol),
    do: {:note, "no breakdown: update it"}

  def breakdown(_worker, _now), do: {:note, "not measured yet"}

  defp cleanups(%{} = cleanups, now) do
    for {key, label} <- @rules do
      with %{} = record <- cleanups[key],
           %DateTime{} = at <- time_of(record["at"]),
           freed when is_integer(freed) <- count(record["freed"]) do
        "#{label} #{Format.ago_phrase(at, now)}, freed #{size(freed)}"
      else
        _never -> "#{label}: not run since boot"
      end
    end
  end

  defp cleanups(_other, _now),
    do: for({_key, label} <- @rules, do: "#{label}: not run since boot")

  defp measured(%{disk_reported_at: %DateTime{} = at}, now),
    do: "measured #{Format.ago_phrase(at, now)}"

  defp measured(_worker, _now), do: nil

  @doc false
  @spec size(non_neg_integer()) :: String.t()
  def size(bytes) when bytes >= 1_073_741_824,
    do: :erlang.float_to_binary(bytes / 1_073_741_824, decimals: 1) <> " GiB"

  def size(bytes) when bytes >= 1_048_576,
    do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MiB"

  def size(bytes) when bytes >= 1024, do: "#{div(bytes, 1024)} KiB"
  def size(bytes), do: "#{bytes} B"

  # -- small guards -----------------------------------------------------------------------------

  # Text, or nothing: a map where a string belongs is left out and never raised on.
  defp text(value) when is_binary(value), do: value
  defp text(_other), do: nil

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(value) when is_list(value), do: length(value)
  defp count(_other), do: nil

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  # -- components -------------------------------------------------------------------------------

  attr :worker, :map, required: true
  attr :connected, :boolean, required: true
  attr :jobs, :list, default: []
  attr :now, :any, required: true

  @doc """
  The switch, the update line and *Update now*. Nothing on a machine the platform made, nor on a
  node with no release.
  """
  def update(assigns) do
    worker = assigns.worker

    assigns =
      assign(assigns,
        shown:
          Updates.permanent?(worker) and not is_nil(WorkerImage.release()) and
            worker.status != :destroyed,
        line: line(worker, assigns.connected, assigns.now),
        can_switch: is_nil(Updates.unable(worker)),
        now_button: Updates.update_now?(worker, assigns.connected),
        running_jobs: Enum.count(assigns.jobs, &(&1.kind != :chat)),
        running_chats: Enum.count(assigns.jobs, &(&1.kind == :chat))
      )

    ~H"""
    <div :if={@shown} class="machine-update" id={"update-#{@worker.id}"}>
      <button
        :if={@can_switch}
        type="button"
        role="switch"
        id={"update-auto-#{@worker.id}"}
        aria-checked={to_string(@worker.auto_update)}
        phx-click="update-auto"
        phx-value-id={@worker.id}
        phx-value-on={to_string(!@worker.auto_update)}
        class="credential-auto machine-update-switch"
      >
        <span>Update automatically</span>
        <span class="credential-switch" aria-hidden="true" />
      </button>
      <p
        :if={@line}
        id={"update-line-#{@worker.id}"}
        class={[
          "machine-line machine-update-line",
          @line.tone == :danger && "text-danger",
          @line.tone == :warning && "text-warning",
          @line.tone == :neutral && "text-ink-3"
        ]}
        title={@line.text}
      >
        {@line.text}
      </p>
      <.confirm
        :if={@now_button}
        id={"update-now-#{@worker.id}"}
        label="Update now"
        act="Update it"
        tone="neutral"
        sentence={update_confirm(@running_jobs, @running_chats)}
        class="machine-update-now"
        phx-click="update-now"
        phx-value-id={@worker.id}
      />
    </div>
    """
  end

  attr :worker, :map, required: true
  attr :now, :any, required: true

  @doc """
  What fills the disk, under the disk meter: neutral, never amber, and drawn while the machine is
  away because it says what was there when measured. Totals per kind only — no ticket, project or
  path, since an owner may have left a project their machine served.
  """
  def disk_breakdown(assigns) do
    assigns = assign(assigns, shown: assigns.worker.status != :destroyed)
    assigns = assign(assigns, breakdown: assigns.shown && breakdown(assigns.worker, assigns.now))

    ~H"""
    <div :if={@shown} class="machine-breakdown" id={"breakdown-#{@worker.id}"}>
      <p :if={match?({:note, _}, @breakdown)} class="machine-line text-ink-3">
        {elem(@breakdown, 1)}
      </p>
      <div :if={match?({:ok, _}, @breakdown)} class="machine-line text-ink-3">
        <% {:ok, breakdown} = @breakdown %>
        <p class="machine-breakdown-sizes">
          <span :for={{label, size} <- breakdown.sizes} class="machine-breakdown-size">
            {label} {size}
          </span>
        </p>
        <p :for={line <- breakdown.cleanups} class="machine-breakdown-cleanup">{line}</p>
        <p :if={breakdown.measured} class="machine-breakdown-age">{breakdown.measured}</p>
      </div>
    </div>
    """
  end

  # -- the owner's writes -----------------------------------------------------------------------

  @doc """
  The switch, from a page's `update-auto` event: scoped to the viewer first, so another person's id
  is *not here*. Returns the flash words for the page, or nil when nothing needs saying.
  """
  @spec set_automatic(map(), map()) :: {:ok, nil} | {:error, String.t()}
  def set_automatic(user, %{"id" => id, "on" => on}) when on in ["true", "false"] do
    case Updates.set_automatic(user, id, on == "true") do
      {:ok, _worker} -> {:ok, nil}
      {:error, :not_found} -> {:error, "That machine is not here."}
    end
  end

  def set_automatic(_user, _params), do: {:error, "That machine is not here."}

  @doc "*Update now*, from a page's `update-now` event: scoped to the viewer first."
  @spec update_now(map(), map()) :: {:ok, nil} | {:error, String.t()}
  def update_now(user, %{"id" => id}) do
    case Updates.update_now(user, id) do
      {:ok, _worker} ->
        {:ok, nil}

      {:error, :not_found} ->
        {:error, "That machine is not here."}

      {:error, :not_connected} ->
        {:error, "That machine is not connected, so it cannot be told."}

      {:error, :nothing_to_do} ->
        {:error, "That machine has nothing to update, or is already updating."}
    end
  end

  def update_now(_user, _params), do: {:error, "That machine is not here."}
end
