defmodule ForgeWeb.PageFileController do
  @moduledoc """
  A page's own files, for the sandboxed frame that runs it (`docs/design/pages.md` § Serving a page's files).

  **No session, no cookie.** A sandboxed document has an opaque origin and the session cookie is
  `SameSite=Lax`, so the browser sends none on the page's own requests for `app.js` or `clip.webm`.
  What names the viewer is the first segment of the path: a `Phoenix.Token` (salt `"forge page"`,
  24 hours) over the viewer, the page and the page version, minted by the page view
  (`token/2`). The relative names the page writes land under the same token.

  **Every request asks again.** The token says who it was minted for and when; whether that person
  is still active and still reaches the page's project is read from the database on each request,
  so a member who was removed loses the files at once. The 24 hours only bounds a leaked path.

  **What is sent.** The files of the page version the token names (never a later one: a page that
  is open keeps its own files until it is reloaded), with the type their extension says, and these
  headers on every response — an error included:

  - `content-security-policy`: `sandbox allow-scripts` (never `allow-same-origin`), `form-action
    'none'`, `base-uri 'none'`, `frame-ancestors` forge's own origin (`'self'` and the
    endpoint's URL, so a forge reached at another address still frames its pages), and fetch
    directives that
    allow the page's own files only, or any address for a viewer who switched the page's toggle on;
  - `referrer-policy: no-referrer`, so the token never leaves in a `Referer`;
  - `x-content-type-options: nosniff`, and `cache-control: private, no-cache`.

  `forge-page.js` is the platform's own library (`priv/page/forge-page.js`), whatever the page
  holds: the worker refuses a page file of that name.

  `Range` is answered with `206` through `Forge.Storage.read_range/3`, at most `@range_cap` a
  response. Only this door is seekable.
  """

  use ForgeWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Forge.Accounts.{Scope, User}
  alias Forge.{Artifacts, Pages, Repo, Storage}
  alias Forge.Pages.{Outside, Page, Version}

  @range_cap 8 * 1024 * 1024

  def show(conn, %{"token" => token, "file" => file}) do
    conn = headers(conn, false)

    with {:ok, {user_id, page_id, number}} <- verify(token),
         {:ok, user, page} <- reach(user_id, page_id),
         %Version{} = version <-
           Repo.get_by(Version, page_id: page.id, version: number) do
      conn = headers(conn, outside?(user, page))
      send_file_of(conn, version, file)
    else
      _no -> not_found(conn)
    end
  end

  # -- who and which ----------------------------------------------------------------------------

  defp verify(token) do
    case ForgeWeb.PageToken.verify(token) do
      {:ok, %{user: user_id, page: page_id, version: number}}
      when is_binary(user_id) and is_binary(page_id) ->
        {:ok, {user_id, page_id, number}}

      _expired_or_forged ->
        :error
    end
  end

  # An approved, unsuspended account that is a member of the page's project, as it is now.
  defp reach(user_id, page_id) do
    with %User{} = user <- Repo.get(User, user_id),
         # Equivalent mutant: dropping `User.active?/1` changes nothing observable, because
         # `Forge.Projects.role/2` (through `Scope.for_project/2`) already answers nil for an
         # account that is not approved or is suspended, and `Forge.Access.can?/2` refuses nil.
         true <- User.active?(user),
         %Page{} = page <- Repo.get(Page, page_id),
         project when not is_nil(project) <- Repo.get(Forge.Projects.Project, page.project_id),
         scope = Scope.for_project(Scope.for_user(user), project),
         true <- Forge.Access.can?(scope, :use) do
      {:ok, user, page}
    else
      _no -> :error
    end
  end

  defp outside?(%User{id: user_id}, %Page{id: page_id}),
    do: Repo.exists?(from(o in Outside, where: o.user_id == ^user_id and o.page_id == ^page_id))

  # -- the headers ------------------------------------------------------------------------------

  defp headers(conn, outside?) do
    conn
    |> put_resp_header("content-security-policy", csp(outside?, request_origin(conn)))
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", "private, no-cache")
    |> delete_resp_header("set-cookie")
  end

  @doc false
  # With the toggle off every fetch directive allows the page's own files and nothing outside:
  # `'self'` and the endpoint's origin together, in case one browser matches `'self'` differently
  # in a sandbox. `'unsafe-inline'` and `'unsafe-eval'` are for the page's own script; `data:` and
  # `blob:` are for media. With it on, any address.
  @spec csp(boolean(), String.t() | nil) :: String.t()
  def csp(outside?, requested \\ nil) do
    origin = ForgeWeb.Endpoint.url()
    # The address this request came to, as well: the endpoint's configured URL is not always the
    # one a browser used (a forge reached by another name), and what `'self'` stands for in a
    # sandboxed document was not established here, so both are named beside it.
    sources = Enum.uniq([origin, requested]) |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    fetch =
      if outside? do
        "default-src * data: blob: 'unsafe-inline' 'unsafe-eval'"
      else
        own = "'self' " <> sources

        "default-src #{own}; " <>
          "script-src #{own} 'unsafe-inline' 'unsafe-eval'; " <>
          "style-src #{own} 'unsafe-inline'; " <>
          "img-src #{own} data: blob:; " <>
          "media-src #{own} data: blob:; " <>
          "font-src #{own} data:; " <>
          "connect-src #{own} data: blob:; " <>
          "object-src 'none'"
      end

    fetch <>
      "; sandbox allow-scripts; form-action 'none'; base-uri 'none'; " <>
      "frame-ancestors 'self' #{sources}"
  end

  defp request_origin(%Plug.Conn{scheme: scheme, host: host, port: port}),
    do: "#{scheme}://#{host}:#{port}"

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "not found")
  end

  # -- the file ---------------------------------------------------------------------------------

  defp send_file_of(conn, %Version{} = version, file) do
    if file == Pages.reserved_file(),
      do: send_library(conn),
      else: send_member(conn, version, file)
  end

  defp send_library(conn) do
    path = Application.app_dir(:forge, "priv/page/" <> Pages.reserved_file())

    case File.read(path) do
      {:ok, bytes} ->
        conn |> put_resp_content_type("text/javascript") |> send_resp(200, bytes)

      {:error, _gone} ->
        not_found(conn)
    end
  end

  defp send_member(conn, %Version{files: files}, file) do
    with %{^file => id} <- files,
         %Artifacts.Version{} = stored <- Repo.get(Artifacts.Version, id) do
      conn
      |> put_resp_content_type(content_type(file), nil)
      |> put_resp_header("accept-ranges", "bytes")
      |> deliver(stored)
    else
      _no -> not_found(conn)
    end
  end

  defp content_type(file) do
    type = MIME.from_path(file)

    if String.starts_with?(type, "text/") or type in ["application/javascript"],
      do: type <> "; charset=utf-8",
      else: type
  end

  defp deliver(conn, stored) do
    case get_req_header(conn, "range") do
      [range | _] -> ranged(conn, stored, range)
      [] -> whole(conn, stored)
    end
  end

  # The path `Artifacts.served/2` downloads a large blob to, which is removed once it is sent.
  defp whole(conn, stored) do
    {:ok, path} = Plug.Upload.random_file("forge-page")

    case Artifacts.served(stored, path) do
      {kind, bytes} when kind in [:text, :bytes] ->
        File.rm(path)
        send_resp(conn, 200, bytes)

      {:file, ^path} ->
        try do
          send_file(conn, 200, path)
        after
          File.rm(path)
        end

      {:error, _reason} ->
        File.rm(path)
        not_found(conn)
    end
  end

  defp ranged(conn, stored, header) do
    with {:ok, size} <- size(stored),
         {:ok, first, last} <- parse_range(header, size) do
      read = min(last - first + 1, @range_cap)
      last = first + read - 1

      case read_range(stored, first, read) do
        {:ok, bytes} ->
          conn
          |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
          |> send_resp(206, bytes)

        {:error, _reason} ->
          not_found(conn)
      end
    else
      :unsatisfiable ->
        {:ok, size} = size(stored)

        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")

      :whole ->
        whole(conn, stored)

      {:error, _reason} ->
        not_found(conn)
    end
  end

  # `bytes=a-b`, `bytes=a-` and `bytes=-n`. Anything else — another unit, several ranges, a
  # malformed one — is no range at all, which a server may answer with the whole file.
  defp parse_range("bytes=" <> spec, size) do
    case Regex.run(~r/\A(\d*)-(\d*)\z/, String.trim(spec)) do
      [_, "", ""] ->
        :whole

      [_, "", suffix] ->
        suffix(String.to_integer(suffix), size)

      [_, from, ""] ->
        bounded(String.to_integer(from), size - 1, size)

      [_, from, to] ->
        bounded(String.to_integer(from), min(String.to_integer(to), size - 1), size)

      _other ->
        :whole
    end
  end

  defp parse_range(_other_unit, _size), do: :whole

  defp suffix(0, _size), do: :unsatisfiable
  defp suffix(_n, 0), do: :unsatisfiable
  defp suffix(n, size), do: {:ok, max(size - n, 0), size - 1}

  defp bounded(first, last, size) when first >= size or first > last, do: size_check(first, size)
  defp bounded(first, last, _size), do: {:ok, first, last}

  # A first byte past the end is unsatisfiable; a last before the first is a malformed range, which
  # is no range (RFC 9110 § 14.1.2).
  defp size_check(first, size) when first >= size, do: :unsatisfiable
  defp size_check(_first, _size), do: :whole

  defp size(%Artifacts.Version{blob_uri: "store:" <> _ = uri}) do
    with {:ok, key} <- key(uri),
         {:ok, %{size: size}} <- Storage.read_range(key, 0, 0) do
      {:ok, size}
    else
      _no -> {:error, :not_found}
    end
  end

  defp size(stored) do
    case Artifacts.content(stored) do
      {:ok, bytes} -> {:ok, byte_size(bytes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_range(%Artifacts.Version{blob_uri: "store:" <> _ = uri}, offset, length) do
    with {:ok, key} <- key(uri),
         {:ok, %{bytes: bytes}} <- Storage.read_range(key, offset, length) do
      {:ok, bytes}
    end
  end

  defp read_range(stored, offset, length) do
    with {:ok, bytes} <- Artifacts.content(stored), do: {:ok, binary_part(bytes, offset, length)}
  end

  defp key(uri) do
    case Storage.key_from_uri(uri) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :not_found}
    end
  end
end
