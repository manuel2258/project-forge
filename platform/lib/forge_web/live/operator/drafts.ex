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

  **It holds every text field of the form, so no form holding a secret may use it.** The change
  event carries the whole form and this keeps all of it, which is what lets one key put a
  comment and a chosen type back together. The day a form with a secret or a password in it
  wants its draft back, that value would live in this map and in the page's assigns: give the
  form a per-field allowlist here first, and read `docs/design/secrets.md` before deciding it is
  acceptable at all. The seven forms that do not recover yet are listed in
  `ForgeWeb.ReconnectTest`, and four of them are why this paragraph exists.

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
  # The `""` default is an equivalent mutant against `nil`: every caller that relies on the
  # default renders the result into an attribute or a textarea body, where HEEx draws `nil` as
  # nothing, and the one caller that needs to tell "" from nothing passes its own fallback.
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
  def handle(event, params, socket), do: dispatch(event, params, socket)

  # Split from `handle/3` so that `authorization_inventory_test.exs` can see the event at all:
  # it scans source for `def handle_event`, `defp act` and `defp dispatch` heads, and a clause
  # written on `def handle` names an event the inventory cannot read. `QuestionForm` splits them
  # for the same reason.
  #
  # `is_binary(form)` is an equivalent mutant: a crafted payload naming a map or a list would be
  # stored under that key instead of dropped, and nothing draws a key no form was rendered with,
  # so no test can see the difference. Same for `is_binary(value)`, which keeps the map to what a
  # text field can hold — what it drops today is `_target`, which has already been turned into a
  # list by the time a handler sees it (`deps/phoenix_live_view`, `decode_merge_target/1`), which
  # is why it is not excluded by name here.
  defp dispatch("draft:change", %{"draft" => form} = params, socket) when is_binary(form) do
    typed =
      for {key, value} <- params, is_binary(value), key != "draft", into: %{} do
        {key, value}
      end

    {:state, Component.assign(socket, :drafts, Map.put(drafts(socket), form, typed))}
  end

  defp dispatch(_event, _params, _socket), do: :unknown

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
