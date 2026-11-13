defmodule ForgeWeb.UserLive.Confirmation do
  @moduledoc """
  An emailed link, opened (`21g`, `docs/design/ui.md` § Signing in). It asks the question it
  means — is this your own device? — with the common answer filled. The first sign-in confirms
  the address and later ones only sign in; both get the same two answers, which decide whether
  the session is remembered (`remember_me`). A link that no longer works goes back to the link's
  own screen with the line under its field.

  It wears the same head as every sign-in screen, and **focuses no button**: a button that opens
  with the focus ring reads as already chosen (UX pass, A29).
  """

  use ForgeWeb, :live_view

  alias Forge.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.sign_in flash={@flash}>
      <div id="sign-in-link" class="signin signin-sent">
        <ForgeWeb.UserLive.Login.brand />
        <h1 class="signin-sent-title">Welcome, {@user.email}</h1>
        <p :if={!@current_scope} class="signin-sent-text">Is this your own device?</p>

        <.form
          for={@form}
          id={if @user.confirmed_at, do: "login_form", else: "confirmation_form"}
          phx-submit="submit"
          action={
            if @user.confirmed_at,
              do: ~p"/users/log-in",
              else: ~p"/users/log-in?_action=confirmed"
          }
          phx-trigger-action={@trigger_submit}
          class="signin-answers"
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button phx-disable-with="Signing in…" variant="primary" size="xl" class="w-full">
              Sign in
            </.button>
          <% else %>
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Signing in…"
              variant="primary"
              size="xl"
              class="w-full"
            >
              Yes, keep me signed in
            </.button>
            <.button phx-disable-with="Signing in…" variant="outline" size="xl" class="w-full">
              No, just this once
            </.button>
          <% end %>
        </.form>

        <p :if={!@user.confirmed_at} class="signin-note">
          If you prefer passwords, you can turn them on in your settings.
        </p>
      </div>
    </Layouts.sign_in>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:sign_in_error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in?way=link")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
