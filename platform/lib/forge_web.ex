defmodule ForgeWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use ForgeWeb, :controller
      use ForgeWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt manifest.webmanifest)

  @doc """
  The first-segment prefixes at which a release also serves a top-level file of `static_paths/0`
  under its digested name.

  `Plug.Static`'s `:only` compares the first segment of a request exactly, and `mix phx.digest`
  names `manifest.webmanifest` `manifest-<md5>.webmanifest` — which is the address a page links,
  because `~p` of a static file maps through `cache_manifest.json`. So `only` alone answers the
  plain address and 404s the one the page renders, for every top-level file and in no other
  environment (nothing is digested in dev or test). Files under a directory are not affected: their
  first segment is the directory.

  One prefix per entry with an extension (`favicon-`, `robots-`, `manifest-`), derived from the one
  list so that a top-level file added to it is served digested with no second edit. The trailing `-`
  is what Phoenix's digester writes (`"\#{rootname}-\#{md5}\#{ext}"`).

  The `-` also keeps out a file that only starts with the same letters: `manifesto.txt` is not
  `manifest-<md5>.webmanifest`. Nothing a release builds has such a name, so it is a rule against a
  file someone adds later, and `digested_static_test.exs` has one.
  """
  @spec static_prefixes() :: [String.t()]
  def static_prefixes do
    for path <- static_paths(), Path.extname(path) != "", do: Path.rootname(path) <> "-"
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: ForgeWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: ForgeWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components, and the design's primitives (docs/design/ui.md § Components)
      import ForgeWeb.CoreComponents
      import ForgeWeb.UI.Navigation
      import ForgeWeb.UI.Decisions
      import ForgeWeb.UI.Forms
      import ForgeWeb.UI.Data
      import ForgeWeb.UI.Feedback

      # Common modules used in templates
      alias ForgeWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ForgeWeb.Endpoint,
        router: ForgeWeb.Router,
        statics: ForgeWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
