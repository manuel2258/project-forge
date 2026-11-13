defmodule ForgeWeb.UserLive.Pending do
  @moduledoc """
  What a pending account sees, and the only thing it sees.

  A first login creates the account — `docs/design/identity.md` § Approval — and a node admin
  decides. Until then there is nothing to show and nothing to do, so this page says so plainly
  and offers the one action that is genuinely available: logging out.

  It is drawn in the sign-in frame, not the frame (`Layouts.sign_in/1`): every place the frame
  leads to redirects this account back here, and a row of links that bounce you back reads as a
  broken product rather than a closed door.
  """

  use ForgeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Waiting for approval")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.sign_in flash={@flash}>
      <div id="pending" class="signin signin-sent">
        <h1 class="signin-sent-title">Waiting for approval</h1>
        <p class="signin-sent-text">
          Your account exists and is waiting for an administrator of this node to approve it.
          Nothing here is available until then.
        </p>
        <p class="signin-address">{@current_scope.user.email}</p>
        <.button href={~p"/users/log-out"} method="delete" variant="outline" size="xl" class="w-full">
          Sign out
        </.button>
      </div>
    </Layouts.sign_in>
    """
  end
end
