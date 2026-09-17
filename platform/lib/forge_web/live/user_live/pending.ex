defmodule ForgeWeb.UserLive.Pending do
  @moduledoc """
  What a pending account sees, and the only thing it sees.

  A first login creates the account — `docs/design/identity.md` § Approval — and a node admin
  decides. Until then there is nothing to show and nothing to do, so this page says so plainly
  and offers the one action that is genuinely available: logging out.

  The nav is off. Every link in it leads somewhere this account is redirected away from, and a
  row of links that bounce you back here reads as a broken product rather than a closed door.
  """

  use ForgeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Waiting for approval")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={false} measure="34rem">
      <h1 class="text-2xl font-semibold -tracking-[.025em]">Waiting for approval</h1>

      <p class="mt-3 text-sm/[1.55] opacity-70">
        Your account exists and is waiting for an administrator of this node to approve it.
        Nothing here is available until then.
      </p>

      <p class="mt-4 font-mono text-[12.5px] opacity-60">{@current_scope.user.email}</p>

      <.link
        href={~p"/users/log-out"}
        method="delete"
        class="mt-6 inline-flex min-h-[46px] items-center rounded-field border border-base-300 px-3 text-sm hover:border-base-content/30"
      >
        Log out
      </.link>
    </Layouts.app>
    """
  end
end
