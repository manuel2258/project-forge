defmodule Forge.DigestedStatic do
  @moduledoc """
  A release's digested static files, made by Phoenix's own digester and put where the endpoint
  serves from, for the tests that ask the endpoint for what a production page links.

  The test environment digests nothing (`cache_static_manifest` is unset), so a page there links
  `/manifest.webmanifest` and every request a test makes for a top-level file lands on the plain
  name, which `Plug.Static`'s `:only` matches. In a release `mix phx.digest` has renamed it
  `manifest-<md5>.webmanifest` and the page links that. `put!/2` runs `Phoenix.Digester.compile/3`,
  which `mix phx.digest` is, on the files it is given and copies the result into the top level of
  `priv/static`; `remove!/1` takes exactly those files out again.

  **Two modules must not digest the same bytes.** The partitions of the suite share one `priv/static`
  and a name is the md5 of its content: the second to put a file finds it there, leaves it, and
  does not remove it, so the first one's `remove!/1` takes it from under the second.
  `digested_static_test.exs` puts the real files and `installed_app_test.exs` puts a manifest with
  a trailing newline, which is the same JSON under another name.
  """

  defp static, do: Application.app_dir(:forge, "priv/static")

  @type put :: %{
          latest: %{String.t() => String.t()},
          files: [String.t()]
        }

  @doc """
  Digests `files` (a map of name to content) and copies what the digester wrote into the top level
  of `priv/static`. `latest` maps each name to its digested name, as `cache_manifest.json` does;
  `files` is every name copied, for `remove!/1`: the digested copies, and the originals of any file
  `priv/static` does not already have, which is how a test puts a file the endpoint must not serve.
  The digester's `cache_manifest.json` is copied only with `manifest: true`, for the same reason.
  """
  @spec put!(%{String.t() => binary}, keyword) :: put
  def put!(files, opts \\ []) do
    tmp = Path.join(System.tmp_dir!(), "forge-digest-#{System.unique_integer([:positive])}")
    input = Path.join(tmp, "in")
    output = Path.join(tmp, "out")
    File.mkdir_p!(input)
    for {name, content} <- files, do: File.write!(Path.join(input, name), content)

    Phoenix.Digester.compile(input, output, true)

    latest = output |> Path.join("cache_manifest.json") |> File.read!() |> Jason.decode!()

    # What is already in `priv/static` (the real originals) is left where it is and so is not removed.
    keep =
      for name <- File.ls!(output),
          opts[:manifest] || name != "cache_manifest.json",
          not File.exists?(Path.join(static(), name)),
          do: name

    for name <- keep, do: File.cp!(Path.join(output, name), Path.join(static(), name))
    File.rm_rf!(tmp)

    %{latest: latest["latest"], files: keep}
  end

  @doc "Removes what `put!/2` copied."
  @spec remove!(put) :: :ok
  def remove!(%{files: files}) do
    for name <- files, do: File.rm!(Path.join(static(), name))
    :ok
  end
end
