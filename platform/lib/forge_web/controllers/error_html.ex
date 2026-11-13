defmodule ForgeWeb.ErrorHTML do
  @moduledoc """
  The pages the endpoint renders for an HTML request that failed (`config/config.exs`
  `render_errors`).

  **Not found keeps the frame** (`docs/design/ui.md` § Not found, `20c`): a signed-in, approved
  person gets the frame every page has — the queue button works — with what was asked for, the
  likeliest reasons and the two places worth going (`ForgeWeb.NotFound`). It is drawn without a
  socket, since nothing on it changes. Anybody else gets the sign-in screens' frame, which tells
  nothing about the node, and a way to sign in. The same page answers an address no route
  matches — the removed `/board` and `…/review` — and a row a page could not find, which a
  project the viewer is not a member of is (`ForgeWeb.Access`).

  `403` is `ForgeWeb.NotAllowed`, raised for `/accounts` alone. Anything else is its status line.
  """
  use ForgeWeb, :html

  alias Forge.Accounts.{Scope, User}
  alias ForgeWeb.{Capacity, NotFound}

  def render("404.html", %{conn: conn}),
    do: page(conn, "Not found", &NotFound.describe(conn.path_info, &1))

  def render("403.html", %{conn: conn}),
    do: page(conn, "Not allowed", fn _scope -> NotFound.not_allowed() end)

  # Without a request — a template rendered on its own — there is nobody to draw the frame for.
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)

  defp page(conn, title, describe) do
    inner =
      case viewer(conn) do
        %User{} = user ->
          scope = Scope.for_user(user)

          signed_in(%{
            title: title,
            code: conn.status,
            miss: describe.(scope),
            current_scope: scope,
            frame: %{count: Forge.Queue.count(user), open: nil, menu: nil},
            capacity: Capacity.of(user)
          })

        nil ->
          signed_out(%{code: conn.status})
      end

    Layouts.root(%{page_title: title, inner_content: inner})
  end

  # The scope the request already resolved, or — for an address no route matched, which no
  # pipeline ran for — the session's or the remember-me cookie's, read by `ForgeWeb.UserAuth`
  # itself, so that this page and every other agree on who is signed in. Only an approved,
  # unsuspended account is drawn the frame; a pending one is not yet anybody's here.
  defp viewer(conn) do
    user =
      case conn.assigns do
        %{current_scope: %Scope{user: %User{} = user}} -> user
        _none -> ForgeWeb.UserAuth.session_user(conn)
      end

    # Asking only `approved_at` here instead is an equivalent mutant: a suspended account's
    # session already resolves to nil (`Accounts.get_user_by_session_token/1`) and the router's
    # pipelines refuse it, so no suspended user reaches this line. No test is written for it.
    if user && User.active?(user), do: user
  end

  defp signed_in(assigns) do
    ~H"""
    <Layouts.app
      section="Menu"
      flash={%{}}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title={@title}
      subline={@miss.asked}
      context={@miss.project && {@miss.project, ~p"/projects/#{@miss.project}"}}
      back={{"Queue", ~p"/"}}
    >
      <section id="not-found" class="not-found">
        <p class="not-found-code">{@code}</p>
        <h2 id="not-found-headline" class="not-found-headline">{@miss.headline}</h2>
        <p id="not-found-reasons" class="not-found-reasons">{@miss.reasons}</p>
        <nav id="not-found-places" class="not-found-places" aria-label="Where to go">
          <.link :for={place <- @miss.places} href={place.path} class="not-found-place">
            {place.label} <span aria-hidden="true">›</span>
          </.link>
        </nav>
      </section>
    </Layouts.app>
    """
  end

  defp signed_out(assigns) do
    ~H"""
    <Layouts.sign_in flash={%{}}>
      <section id="not-found" class="not-found">
        <p class="not-found-code">{@code}</p>
        <h2 id="not-found-headline" class="not-found-headline">There is nothing here.</h2>
        <p id="not-found-reasons" class="not-found-reasons">
          Sign in to see what this address holds for you.
        </p>
        <nav class="not-found-places" aria-label="Where to go">
          <.link href={~p"/users/log-in"} class="not-found-place">
            Sign in <span aria-hidden="true">›</span>
          </.link>
        </nav>
      </section>
    </Layouts.sign_in>
    """
  end
end
