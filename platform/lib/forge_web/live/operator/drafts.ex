defmodule ForgeWeb.Operator.Drafts do
  @moduledoc """
  What a person typed into a card's box and has not sent, held by the page so that a dropped
  socket does not take it with it (`docs/design/ui.md` § A reconnect is not a reload).

  **The page holding it is what makes it survive, because the client gives it back.** On a
  rejoin LiveView copies every `form[phx-change]` that has an `id` out of the live DOM and
  re-pushes that form's change event with what was typed, before it applies the new mount's
  render (`deps/phoenix_live_view/assets/js/phoenix_live_view/view.ts`, `maybeRecoverForms`).
  A form with no `phx-change` is not copied and not replayed, so its box is drawn empty by the
  new render and what was in it is gone. That is the whole of the fix: give the box's form an
  `id` and a `phx-change` that lands here, and draw the box from what landed.

  A form names its own draft in a hidden `draft` field, as a question form names itself in
  `form` — the change event carries no element id, and the hidden field is the one thing that
  survives being serialised. The value is the form's whole payload, so a card with a choice
  beside its text — a proposal's ticket type — recovers both from one key.

  **A draft lives until its form is sent.** `forget/2` on a successful submit, or a comment
  typed on an approval would come back on the next approval of the same ticket, and a saved
  document would be drawn from the draft rather than from the version that was just written.
  """

  alias Phoenix.Component

  @doc "The draft state a page starts with: nothing typed."
  @spec init() :: map()
  def init, do: %{}

  @doc """
  What `form` holds for the input named `name`, or `fallback` when the form has no draft —
  which is every form until something is typed into it, and every form again after a send.
  """
  @spec field(map(), String.t(), String.t(), String.t() | nil) :: String.t() | nil
  def field(drafts, form, name, fallback \\ "") do
    case drafts |> Map.get(form, %{}) |> Map.get(name) do
      nil -> fallback
      value -> value
    end
  end

  @doc """
  Handles a draft change: `{:state, socket}`, which needs no reload, or `:unknown` for anything
  else, a payload naming no form included.
  """
  @spec handle(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:state, Phoenix.LiveView.Socket.t()} | :unknown
  def handle("draft:change", %{"draft" => form} = params, socket) when is_binary(form) do
    typed =
      for {key, value} <- params, is_binary(value), key not in ~w(draft _target), into: %{} do
        {key, value}
      end

    {:state, Component.assign(socket, :drafts, Map.put(drafts(socket), form, typed))}
  end

  def handle(_event, _params, _socket), do: :unknown

  @doc """
  Drops what a form held, after a submit that committed it. A `nil` form is every submit that
  came from no form of ours, which drops nothing.
  """
  @spec forget(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def forget(socket, nil), do: socket

  def forget(socket, form),
    do: Component.assign(socket, :drafts, Map.delete(drafts(socket), form))

  # A page that never drew a card has no `:drafts` yet; an event naming one is still handled.
  defp drafts(socket), do: Map.get(socket.assigns, :drafts, %{})
end
