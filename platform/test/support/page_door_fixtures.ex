defmodule ForgeWeb.PageDoorFixtures do
  @moduledoc """
  A page with a version, built from the rows the doors read (`Forge.Pages`), for the tests of the
  three doors to it: `ForgeWeb.JobPagesController`, `ForgeWeb.Api.PageController` and
  `ForgeWeb.PageFileController`.

  The files are blobs `<page>/<file>` in whichever `Forge.Storage` the test pointed at a directory
  of its own, recorded as a job's publish records them.
  """

  alias Forge.{Artifacts, Pages, Repo, Storage}
  alias Forge.Pages.Version

  @doc """
  The page `name` in `scope`, with `files` (`%{"index.html" => bytes}`) as its next version.
  `{page, version}`.
  """
  def published!(scope, name, files \\ %{"index.html" => "<h1>hi</h1>"}) do
    {:ok, page} = Pages.ensure(scope, name)

    ids =
      Map.new(files, fn {file, bytes} ->
        key = "page-door/#{System.unique_integer([:positive])}"
        {:ok, %{hash: hash}} = Storage.put(key, bytes)

        {:ok, version} =
          Artifacts.record_version(
            Pages.artifact_scope(scope),
            name <> "/" <> file,
            :blob,
            {:user, Ecto.UUID.generate()},
            %{blob_uri: Storage.uri(key), content_hash: hash}
          )

        {file, version.id}
      end)

    next = (Pages.latest_version(page) || %{version: 0}).version + 1

    version =
      Repo.insert!(%Version{page_id: page.id, version: next, files: ids})

    {page, version}
  end
end
