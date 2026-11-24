defmodule ForgeWeb.PageToken do
  @moduledoc """
  The signed path a page's frame is served under (`docs/design/pages.md` § Serving a page's files).

  A sandboxed document has an opaque origin and the session cookie is `SameSite=Lax`, so the
  browser sends **no cookie** on the page's own requests for its script, images and video. The page
  view signs `{viewer, page, version}` into the frame's address, `/page-files/<token>/index.html`,
  and the page's relative names land under the same token. The token proves who opened the page
  and which version; it is **not an authorisation**: `ForgeWeb.PageFileController` asks again, on
  every request, whether the viewer still reaches the project, so a member removed loses the files
  at once. The 24 hours only bounds how long a leaked path would be read.

  This is the second `Phoenix.Token` in the platform and the one that rides in a path, which
  `docs/design/storage.md` says.
  """

  @salt "forge page"
  @max_age 24 * 60 * 60

  @doc "How long a token is good, in seconds."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc "The token for `user_id` viewing `version` of `page_id`."
  @spec sign(String.t(), String.t(), pos_integer()) :: String.t()
  def sign(user_id, page_id, version),
    do:
      Phoenix.Token.sign(ForgeWeb.Endpoint, @salt, %{
        user: user_id,
        page: page_id,
        version: version
      })

  @doc "What a token says, or why it is no good."
  @spec verify(String.t()) ::
          {:ok, %{user: String.t(), page: String.t(), version: pos_integer()}}
          | {:error, :invalid | :expired}
  def verify(token) when is_binary(token),
    do: Phoenix.Token.verify(ForgeWeb.Endpoint, @salt, token, max_age: @max_age)

  def verify(_other), do: {:error, :invalid}
end
