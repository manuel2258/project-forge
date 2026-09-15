defmodule ForgeWeb.Conversations do
  @moduledoc """
  How a conversation is drawn in a list.

  Two surfaces show one — `/chats` and a project's page — so there is one of this rather than
  two. What differs between them is which conversations, not what a row looks like.
  """

  use Phoenix.Component
  use ForgeWeb, :verified_routes

  import ForgeWeb.Indicators

  alias ForgeWeb.Format

  @doc """
  The box you say things in.

  **Enter sends and shift-enter makes a newline**, which is what every chat client does and so
  what a person's hands already expect. A textarea does neither on its own, so both surfaces
  share this rather than each growing its own handler — and its own subtly different one.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :rows, :string, default: "3"
  attr :placeholder, :string, default: "Say something"
  attr :label, :string, default: nil

  def message_box(assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="text-sm font-medium">{@label}</label>
      <textarea
        id={@id}
        name={@name}
        rows={@rows}
        phx-hook=".SendOnEnter"
        phx-debounce="200"
        placeholder={@placeholder}
        class={[
          "w-full rounded-box border border-base-300 bg-base-100 p-3 text-sm/[1.6]",
          @label && "mt-2"
        ]}
      >{@value}</textarea>
      <p class="mt-1 font-mono text-[11px] opacity-40">Enter sends · shift-enter for a new line</p>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".SendOnEnter">
      export default {
        mounted() {
          this.el.addEventListener("keydown", (event) => {
            if (event.key !== "Enter" || event.shiftKey) return

            // An input method editor uses Enter to commit the character being composed. Sending
            // then would send half a word, so composition always wins.
            if (event.isComposing || event.keyCode === 229) return

            event.preventDefault()
            this.el.form?.requestSubmit()
          })
        }
      }
    </script>
    """
  end

  attr :summaries, :list, required: true
  attr :now, :any, required: true
  attr :project, :boolean, default: true, doc: "name the project; false on a project's own page"
  attr :empty, :string, default: "No conversations yet."

  def list(assigns) do
    ~H"""
    <p :if={@summaries == []} class="mt-3 text-sm opacity-60">{@empty}</p>

    <ol :if={@summaries != []} class="mt-3 flex flex-col">
      <li :for={summary <- @summaries} class="border-t border-base-300">
        <%!-- The whole row is the target: it goes to one place and does nothing else, so there
              is no second gesture inside it to compete with. --%>
        <.link
          navigate={~p"/chats/#{summary.chat.id}"}
          class="flex flex-col gap-[6px] py-[15px] hover:opacity-100"
        >
          <div class="flex items-start justify-between gap-4">
            <div class="flex flex-wrap items-center gap-2 font-mono text-[11px] tracking-[.14em] uppercase opacity-70">
              <span :if={@project}>{summary.project.name}</span>
              <span :if={@project and summary.ticket} aria-hidden="true">·</span>
              <span :if={summary.ticket}>#{summary.ticket.number}</span>
              <span :if={summary.waiting} class="text-accent">· waiting on you</span>
              <.job_status :if={not summary.live} status={summary.chat.status} />
            </div>
            <span class="shrink-0 font-mono text-[12.5px] opacity-50">
              {Format.ago(summary.chat.inserted_at, @now)}
            </span>
          </div>

          <%!-- The last thing said, which is what tells one conversation from another — a chat
                has no title, and the first message is often not what it became about. --%>
          <p class="text-sm/[1.5] opacity-80">
            <span class="opacity-50">{speaker(summary.said)}</span>
            {said(summary.said)}
          </p>

          <div class="font-mono text-[11px] opacity-50">
            {summary.chat.turns} {noun(summary.chat.turns, "turn")} · {Format.windows(
              summary.chat.cost_usd
            ) || "—"}
          </div>
        </.link>
      </li>
    </ol>
    """
  end

  defp speaker({:user, _text}), do: "you:"
  defp speaker({:agent, _text}), do: "agent:"
  defp speaker(nil), do: ""

  defp said(nil), do: "Nothing said yet."

  defp said({_role, text}) do
    text
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("")
    |> String.slice(0, 140)
  end

  defp noun(1, word), do: word
  defp noun(_count, word), do: word <> "s"
end
