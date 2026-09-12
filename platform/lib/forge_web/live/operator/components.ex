defmodule ForgeWeb.Operator.Components do
  @moduledoc "Cards for the things a person decides: questions, approvals, transitions."

  use ForgeWeb, :html

  attr :question, :map, required: true
  attr :ticket_id, :string, required: true

  def question_card(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm" id={"question-#{@question.id}"}>
      <div class="card-body gap-3 p-4">
        <div class="text-xs uppercase tracking-wide opacity-60">
          {if @question.blocking, do: "Blocking question", else: "Question"} · {@question.key}
        </div>
        <p class="text-base">{@question.text}</p>
        <blockquote :if={@question.anchor} class="border-l-4 border-base-300 pl-3 text-sm opacity-70">
          {@question.anchor}
        </blockquote>
        <div class="flex flex-wrap gap-2">
          <button
            :for={option <- @question.options}
            type="button"
            class={["btn btn-sm", option == @question.default && "btn-primary"]}
            phx-click="answer"
            phx-value-ticket={@ticket_id}
            phx-value-key={@question.key}
            phx-value-choice={option}
          >
            {option}
          </button>
        </div>
        <form phx-submit="answer_text" class="join w-full">
          <input type="hidden" name="ticket" value={@ticket_id} />
          <input type="hidden" name="key" value={@question.key} />
          <input
            type="text"
            name="text"
            placeholder="or answer in your own words"
            class="input input-sm join-item w-full"
            required
          />
          <button type="submit" class="btn btn-sm join-item">Send</button>
        </form>
      </div>
    </div>
    """
  end

  attr :ticket, :map, required: true
  attr :pending, :map, required: true

  def approval_card(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm" id={"approval-#{@ticket.id}"}>
      <div class="card-body gap-3 p-4">
        <div class="text-xs uppercase tracking-wide opacity-60">Approval</div>
        <p>
          <span class="font-mono">{@pending["from"]}</span>
          → <span class="font-mono">{@pending["to"]}</span>
          on <span class="font-mono">{@pending["outcome"]}</span>
        </p>
        <p class="text-sm opacity-70">
          Approves the latest version of {Enum.join(@pending["approve"], ", ")}
        </p>
        <form phx-submit="decide" class="flex flex-col gap-2">
          <input type="hidden" name="ticket" value={@ticket.id} />
          <input
            type="text"
            name="comment"
            placeholder="comment (optional)"
            class="input input-sm w-full"
          />
          <div class="flex gap-2">
            <button
              type="submit"
              name="decision"
              value="approved"
              class="btn btn-sm btn-primary flex-1"
            >Approve</button>
            <button type="submit" name="decision" value="rejected" class="btn btn-sm flex-1">Reject</button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :ticket, :map, required: true
  attr :transitions, :list, required: true
  attr :label, :string, required: true

  def transition_card(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm" id={"transitions-#{@ticket.id}"}>
      <div class="card-body gap-3 p-4">
        <div class="text-xs uppercase tracking-wide opacity-60">{@label}</div>
        <p class="text-sm">In <span class="font-mono">{@ticket.state}</span>. Take a transition:</p>
        <div class="flex flex-wrap gap-2">
          <button
            :for={to <- @transitions}
            type="button"
            class="btn btn-sm"
            phx-click="transition"
            phx-value-ticket={@ticket.id}
            phx-value-to={to}
          >
            → {to}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :ticket, :map, required: true
  attr :project, :string, required: true

  def ticket_link(assigns) do
    ~H"""
    <.link navigate={~p"/tickets/#{@project}/#{@ticket.number}"} class="link link-hover font-medium">
      {@project}#{@ticket.number} · {@ticket.title}
    </.link>
    """
  end

  attr :status, :atom, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      @status in [:active, :running, :converged] && "badge-info",
      @status in [:done, :finished] && "badge-success",
      @status in [:stuck, :error, :cancelled, :budget_exhausted] && "badge-error",
      @status in [:waiting, :pending, :did_not_converge] && "badge-warning"
    ]}>
      {@status}
    </span>
    """
  end
end
