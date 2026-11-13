defmodule ForgeWeb.UserLive.Login do
  @moduledoc """
  Signing in (`docs/design/ui.md` § Signing in): `21o` with a provider configured — the logo and
  the provider, nothing else — and `21p`, *Other ways*, for a password or an emailed link, which
  is the whole page on a node with no provider.

  Which screen opens is `?way=provider|password|link`, and without one the way this device last
  signed in (`ForgeWeb.SignIn`). A refusal comes back to its own screen and is drawn there, in
  place: a provider's above its button (`21n`), a wrong password or a dead link under the field.
  A wrong password is the pair's, not the password's: its line is under Sign in, since the
  page cannot say (and must not) which of the two was wrong. So the two flashes a refusal comes
  back here with — `:oidc_refusal` for a provider's own
  registered refusal, `:sign_in_error` for every other — are drawn by this page, in place, and
  nowhere else.
  """

  use ForgeWeb, :live_view

  alias Forge.Accounts
  alias Forge.Accounts.Oidc
  alias ForgeWeb.SignIn

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.sign_in flash={@flash}>
      <div :if={@way == :provider} id="sign-in-provider" class="signin signin--provider">
        <.brand large />

        <p :if={@current_scope} class="signin-note">Sign in again to change your account.</p>

        <%!-- The shared notice in danger: the inset edge every notice has, not a bordered card
              of its own (UX re-check #6). --%>
        <.notice
          :if={@refusal}
          id="sign-in-refusal"
          tone="danger"
          role="alert"
          title={"#{@refusal.name} didn't sign you in"}
        >
          It said: <code>{@refusal.code}</code>. {@refusal.reading}
        </.notice>

        <.notice :if={@error} id="sign-in-error" tone="danger" role="alert">
          {@error}
        </.notice>

        <div class="signin-providers">
          <.link
            :for={provider <- @providers}
            id={"sign-in-with-#{provider.id}"}
            href={~p"/auth/oidc/#{provider.id}"}
            class="signin-provider"
          >
            <span class="signin-provider-mark" aria-hidden="true">{initials(provider.name)}</span>
            <span class="signin-provider-text">
              <span class="signin-provider-name">Continue with {provider.name}</span>
              <span class="signin-provider-host">{provider.host}</span>
            </span>
            <span aria-hidden="true">›</span>
          </.link>
        </div>

        <.link id="sign-in-other" patch={~p"/users/log-in?way=password"} class="signin-other">
          Other ways to sign in ▾
        </.link>
      </div>

      <div :if={@way != :provider} id="sign-in-other-ways" class="signin">
        <.link
          :if={@providers != []}
          id="sign-in-back"
          patch={~p"/users/log-in?way=provider"}
          class="signin-back"
        >
          ‹ {back_label(@providers)}
        </.link>

        <.brand />

        <p :if={@current_scope} class="signin-note">Sign in again to change your account.</p>

        <%!-- The switch is two radios in a form of its own: picking one patches to its screen.
              (Not `segmented/1`'s button mode, whose `phx-value-value` a browser's click
              replaces with the button's own empty `value`.) --%>
        <form id="sign-in-way" phx-change="switch-way">
          <.segmented
            id="sign-in-way-switch"
            name="way"
            size="md"
            options={[{"Password", "password"}, {"Email link", "link"}]}
            value={@way}
          />
        </form>

        <.form
          :if={@way == :password}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
          class="signin-form"
        >
          <.input
            readonly={!!@current_scope}
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            id="login_form_password_password"
            name="user[password]"
            value=""
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
          />
          <.input
            id="login_form_password_remember"
            name={@form[:remember_me].name}
            type="checkbox"
            label="Keep me signed in on this device"
            checked
          />
          <.button variant="primary" size="xl" class="w-full">Sign in</.button>
          <%!-- Under the button, not the password field: the refusal is about the pair, and it
                says so in a whole sentence (UX pass, A30). --%>
          <.error_note :if={@error} id="sign-in-password-error">{@error}</.error_note>
        </.form>

        <.form
          :if={@way == :link and is_nil(@sent)}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
          class="signin-form"
        >
          <.input
            readonly={!!@current_scope}
            id="login_form_magic_email"
            name="user[email]"
            value={@form[:email].value}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            errors={List.wrap(@error)}
            phx-mounted={JS.focus()}
          />
          <.button variant="primary" size="xl" class="w-full">Email me a link</.button>
          <p :if={local_mail_adapter?()} class="signin-note">
            This node keeps its mail on <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
          </p>
        </.form>

        <div :if={@way == :link and @sent} id="sign-in-sent" class="signin-sent" role="status">
          <.eyebrow tone="success">✓ sent</.eyebrow>
          <p class="signin-sent-title">Check {@sent}.</p>
          <p class="signin-sent-text">
            The link signs you in on the device you open it on, and works once. It comes only if
            the address has an account here.
          </p>
          <button type="button" phx-click="another-address" class="signin-other">
            Use another address
          </button>
        </div>
      </div>

      <p class="signin-foot">A new account waits for an administrator to approve it.</p>
    </Layouts.sign_in>
    """
  end

  @doc """
  The sign-in head: the app's own favicon as the logo, 72px over the provider (`large`), 44px
  beside the word elsewhere — on *Other ways* and on an emailed link opened (`21g`), so every
  sign-in screen has the same head.
  """
  attr :large, :boolean, default: false

  def brand(assigns) do
    ~H"""
    <div class={["signin-brand", @large && "signin-brand--large"]}>
      <img src={~p"/images/favicon.svg"} alt="" class="signin-logo" />
      <span class="signin-word">forge</span>
      <span :if={@large} class="signin-tagline">
        Sign in to answer what your agents are waiting on.
      </span>
    </div>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    flash = socket.assigns.flash

    email =
      Phoenix.Flash.get(flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    remembered = session["last_sign_in"]

    {:ok,
     assign(socket,
       form: to_form(%{"email" => email}, as: "user"),
       trigger_submit: false,
       sent: nil,
       remembered: remembered,
       providers: buttons(remembered),
       error: Phoenix.Flash.get(flash, :sign_in_error),
       refusal: SignIn.read_refusal(Phoenix.Flash.get(flash, :oidc_refusal))
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    way = way(params["way"], socket.assigns.providers, socket.assigns.remembered)

    # A refusal belongs to the screen it came back to: switching screens leaves it behind.
    socket =
      if socket.assigns[:way],
        do: assign(socket, error: nil, refusal: nil),
        else: socket

    {:noreply, assign(socket, way: way, sent: nil)}
  end

  # The page needs an id, a name and the issuer's host. It does not need a client secret in the
  # socket, where a LiveView crash report would inspect it as part of the process state, so only
  # those three cross into the assigns. The provider this device last used comes first.
  defp buttons(remembered) do
    Oidc.providers()
    |> Enum.map(&%{id: &1.id, name: &1.name, host: SignIn.host(&1.issuer)})
    |> Enum.sort_by(&(remembered != {:oidc, &1.id}))
  end

  # The screen asked for, else the one this device last used, else the provider. A node with no
  # provider has no provider screen.
  defp way("password", _providers, _remembered), do: :password
  defp way("link", _providers, _remembered), do: :link
  defp way(_asked, [], :magic), do: :link
  defp way(_asked, [], _remembered), do: :password
  defp way("provider", _providers, _remembered), do: :provider
  defp way(_asked, _providers, :password), do: :password
  defp way(_asked, _providers, :magic), do: :link
  defp way(_asked, _providers, _remembered), do: :provider

  defp back_label([provider]), do: provider.name
  defp back_label(_providers), do: "Back"

  # Two letters for the provider's tile: the initials of its first two words (`manu.software` →
  # `ms`), or the first two letters of its only one.
  defp initials(name) do
    case String.split(name, ~r/[^[:alnum:]]+/u, trim: true) do
      [one] -> one |> String.slice(0, 2) |> String.downcase()
      [first, second | _rest] -> String.downcase(String.first(first) <> String.first(second))
      [] -> ""
    end
  end

  @impl true
  def handle_event("switch-way", %{"way" => way}, socket) when way in ~w(password link) do
    {:noreply, push_patch(socket, to: ~p"/users/log-in?way=#{way}")}
  end

  def handle_event("switch-way", _params, socket), do: {:noreply, socket}

  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  # Answered the same whether or not the address has an account: the screen says the link comes
  # only if it does, which is true either way and tells nobody which.
  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    {:noreply,
     assign(socket,
       sent: String.slice(email, 0, 160),
       error: nil,
       form: to_form(%{"email" => email}, as: "user")
     )}
  end

  def handle_event("another-address", _params, socket) do
    {:noreply, assign(socket, sent: nil, error: nil)}
  end

  defp local_mail_adapter? do
    Application.get_env(:forge, Forge.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
