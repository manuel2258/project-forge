defmodule ForgeWorker.Job.BlobsTest do
  # The platform's address and the store's transport are application environment.
  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeCore.Job.Result
  alias ForgeWorker.Job.{Blobs, Dir}

  @html "<p>hi"
  @html_hash :crypto.hash(:sha256, @html) |> Base.encode16(case: :lower)

  setup do
    test = self()
    Application.put_env(:forge_worker, :platform_url, "http://platform.test")

    Application.put_env(:forge_worker, :req_options,
      plug: fn conn ->
        send(test, {:put, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "{}")
      end,
      retry: false
    )

    on_exit(fn ->
      Application.delete_env(:forge_worker, :req_options)
      Application.delete_env(:forge_worker, :platform_url)
    end)

    spec = spec(%{produces: ["form@"]})
    job_dir = Dir.prepare(tmp_dir("blobs"), spec)
    page = Path.join([job_dir, "out", "form"])
    File.mkdir_p!(page)

    %{
      job_dir: job_dir,
      page: page,
      staging: Dir.blobs_dir(job_dir),
      assignment: %{
        "job_id" => spec.job_id,
        "outputs" => %{"prefix" => "job/j1/out/", "token" => "t"}
      }
    }
  end

  defp staged(context) do
    Blobs.stage(%Result{status: :finished}, context.job_dir, [], ["form"])
  end

  test "a page's files are reported with their hash, uploaded, and the staging gone", context do
    File.write!(Path.join(context.page, "index.html"), @html)
    File.write!(Path.join(context.page, "app.js"), "js")

    result = context |> staged() |> Blobs.upload(context.assignment, context.staging)

    assert %{"key" => "job/j1/out/2", "size" => 5, "hash" => @html_hash} =
             result.blobs["form/index.html"]

    assert %{"key" => "job/j1/out/1", "hash" => _} = result.blobs["form/app.js"]
    assert result.invalid_blobs == %{}
    refute File.exists?(context.staging)
    assert_receive {:put, "/store/job/j1/out/1"}
    assert_receive {:put, "/store/job/j1/out/2"}
  end

  test "a file whose hash the spec already holds is not uploaded, and says so without a key",
       context do
    File.write!(Path.join(context.page, "index.html"), @html)
    File.write!(Path.join(context.page, "app.js"), "js")

    assignment =
      Map.put(context.assignment, "spec", %{
        "pages" => [
          %{
            "name" => "form",
            "version" => 1,
            "files" => %{"index.html" => %{"hash" => @html_hash, "size" => 5}}
          }
        ]
      })

    result = context |> staged() |> Blobs.upload(assignment, context.staging)

    assert result.blobs["form/index.html"] == %{"hash" => @html_hash, "size" => 5}
    assert %{"key" => _} = result.blobs["form/app.js"]
    assert_receive {:put, _once}
    refute_receive {:put, _twice}
  end

  test "a file this process uploaded last time is skipped, and another page's same name is not",
       context do
    File.write!(Path.join(context.page, "index.html"), @html)

    known = %{"form/index.html" => @html_hash}
    result = staged(context) |> Blobs.upload(context.assignment, context.staging, known: known)
    assert result.blobs["form/index.html"] == %{"hash" => @html_hash, "size" => 5}
    refute_receive {:put, _}

    other = %{"other/index.html" => @html_hash}
    result = staged(context) |> Blobs.upload(context.assignment, context.staging, known: other)
    assert %{"key" => _} = result.blobs["form/index.html"]
  end

  test "a conversation's page file is keyed by its hash and a nonce, not a number", context do
    File.write!(Path.join(context.page, "index.html"), @html)

    upload = fn ->
      context |> staged() |> Blobs.upload(context.assignment, context.staging, keys: :hash)
    end

    first = upload.()
    assert_receive {:put, path}
    second = upload.()
    assert_receive {:put, again}

    # The same bytes uploaded twice — two pages sharing a file, or a file changed A→B→A — are two
    # keys, because the store refuses to overwrite one.
    prefix = "job/j1/out/" <> @html_hash <> "-"
    assert "/store/" <> key = path
    assert String.starts_with?(key, prefix)
    assert key == first.blobs["form/index.html"]["key"]
    assert path != again
    assert second.blobs["form/index.html"]["key"] != key
    assert second.blobs["form/index.html"]["hash"] == @html_hash
    segment = String.replace_prefix(key, "job/j1/out/", "")
    assert Regex.match?(~r/\A[a-z0-9][a-z0-9._-]*\z/, segment)
  end

  test "a page whose index.html was not kept keeps none of its files", context do
    File.write!(Path.join(context.page, "app.js"), "js")
    File.write!(Path.join(context.page, "index.html"), String.duplicate("x", 20))

    Application.put_env(:forge_worker, :max_blob_bytes, 10)
    on_exit(fn -> Application.delete_env(:forge_worker, :max_blob_bytes) end)

    result = staged(context)

    assert result.blobs == %{}
    assert result.invalid_blobs["form/index.html"] =~ "larger than 10 bytes"
    # The one file that was copied, app.js, is gone from staging with the rest of the page.
    refute File.exists?(Path.join(context.staging, "1"))
  end

  test "a page with no file at all stages and reports nothing", context do
    assert %Result{blobs: blobs, invalid_blobs: invalid} = staged(context)
    assert blobs == %{}
    assert invalid == %{}
  end

  test "a group's files carry no hash, whatever the spec holds", context do
    shots = Path.join([context.job_dir, "out", "shots"])
    File.mkdir_p!(shots)
    File.write!(Path.join(shots, "a.png"), "png")

    result = Blobs.stage(%Result{status: :finished}, context.job_dir, ["shots"], [])
    assert result.blobs["shots/a.png"] |> Map.keys() == ["path"]
  end
end
