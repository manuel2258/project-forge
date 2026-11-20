defmodule ForgeWorker.AttachmentsTest do
  @moduledoc """
  The folder of files people attached (`docs/design/attachments.md` § The folder): downloaded once
  through a checked `.partial`, placed under the names the pool spells, and never a path.
  """

  # The Req plug is configured through the application environment, which is global.
  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeCore.Job.Spec
  alias ForgeWorker.{Attachments, RecordingBind}

  setup do
    root = tmp_dir("attachments")
    job_id = uuid()
    job_dir = Path.join(root, job_id)
    File.mkdir_p!(job_dir)
    Application.put_env(:forge_worker, :platform_url, "http://platform.test")
    {:ok, served} = Agent.start_link(fn -> %{} end)

    Application.put_env(:forge_worker, :req_options,
      plug: fn conn ->
        key = String.replace_prefix(conn.request_path, "/store/", "")

        case Agent.get(served, &Map.get(&1, key)) do
          nil -> Plug.Conn.send_resp(conn, 404, "no such key")
          bytes -> Plug.Conn.send_resp(conn, 200, bytes)
        end
      end
    )

    on_exit(fn ->
      Application.delete_env(:forge_worker, :req_options)
      Application.delete_env(:forge_worker, :platform_url)
    end)

    %{root: root, job_dir: job_dir, job_id: job_id, served: served}
  end

  # An entry as the assignment carries it, with its bytes put where the plug serves them.
  defp entry(served, file, bytes, overrides \\ %{}) do
    version_id = uuid()
    key = "upload/" <> uuid()
    # Served under the key it carries too, so that a refusal is the worker's and not a 404.
    Agent.update(served, &Map.merge(&1, %{key => bytes, (overrides["key"] || key) => bytes}))

    Map.merge(
      %{
        "file" => file,
        "version_id" => version_id,
        "key" => key,
        "token" => "tok",
        "size" => byte_size(bytes),
        "hash" => "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      },
      overrides
    )
  end

  defp placed(job_dir), do: job_dir |> Attachments.source_dir() |> File.ls!() |> Enum.sort()

  test "places each name, plain and versioned, read-only", %{job_dir: job_dir, served: served} do
    new = entry(served, "shot.png", "two")
    old = entry(served, "shot.v001.png", "one")

    assert Attachments.sync(job_dir, [new, old]) == []

    assert placed(job_dir) == ["shot.png", "shot.v001.png"]
    source = Attachments.source_dir(job_dir)
    assert File.read!(Path.join(source, "shot.png")) == "two"
    assert File.read!(Path.join(source, "shot.v001.png")) == "one"
    assert %File.Stat{mode: mode} = File.stat!(Path.join(source, "shot.png"))
    assert Bitwise.band(mode, 0o222) == 0
  end

  test "downloads a version once", %{job_dir: job_dir, served: served} do
    one = entry(served, "a.txt", "aaa")
    assert Attachments.sync(job_dir, [one]) == []
    # The platform no longer has it; the machine's copy is what the folder keeps.
    Agent.update(served, fn _ -> %{} end)
    assert Attachments.sync(job_dir, [one]) == []
    assert File.read!(Path.join(Attachments.source_dir(job_dir), "a.txt")) == "aaa"
  end

  test "a name taken by the next version is placed again", %{job_dir: job_dir, served: served} do
    first = entry(served, "a.txt", "one")
    Attachments.sync(job_dir, [first])

    # Version 2 is the plain name now, and version 1 the versioned one.
    second = entry(served, "a.txt", "two")
    first_again = %{first | "file" => "a.v001.txt"}
    assert Attachments.sync(job_dir, [second, first_again]) == []

    source = Attachments.source_dir(job_dir)
    assert File.read!(Path.join(source, "a.txt")) == "two"
    assert File.read!(Path.join(source, "a.v001.txt")) == "one"
  end

  test "a file no longer in the pool is gone from the folder and from the machine",
       %{job_dir: job_dir, served: served} do
    keep = entry(served, "keep.txt", "k")
    drop = entry(served, "drop.txt", "d")
    Attachments.sync(job_dir, [keep, drop])
    cache = Path.join(Path.dirname(Attachments.source_dir(job_dir)), "attachment-cache")
    assert File.ls!(cache) |> length() == 2

    assert Attachments.sync(job_dir, [keep]) == []

    assert placed(job_dir) == ["keep.txt"]
    assert File.ls!(cache) == [keep["version_id"]]
  end

  test "bytes that do not hash to what the platform said leave no file", %{
    job_dir: job_dir,
    served: served
  } do
    good = entry(served, "good.txt", "good")
    bad = entry(served, "bad.txt", "bad", %{"hash" => "sha256:" <> String.duplicate("0", 64)})
    short = entry(served, "short.txt", "short", %{"size" => 99})

    assert Attachments.sync(job_dir, [good, bad, short]) |> Enum.sort() == [
             "bad.txt",
             "short.txt"
           ]

    assert placed(job_dir) == ["good.txt"]
    cache = Path.join(Path.dirname(Attachments.source_dir(job_dir)), "attachment-cache")
    assert File.ls!(cache) == [good["version_id"]]
  end

  test "a file the platform does not have is failed, and the rest still arrive", %{
    job_dir: job_dir,
    served: served
  } do
    ok = entry(served, "ok.txt", "ok")
    gone = entry(served, "gone.txt", "x")
    Agent.update(served, &Map.delete(&1, gone["key"]))

    assert Attachments.sync(job_dir, [ok, gone]) == ["gone.txt"]
    assert placed(job_dir) == ["ok.txt"]
  end

  test "a name is never a path", %{job_dir: job_dir, root: root, served: served} do
    hostile =
      for name <- ["../escape", "/etc/passwd", "a/b", ".hidden", "", "x\n"] do
        entry(served, name, "evil")
      end

    assert Attachments.sync(job_dir, hostile) |> length() == 6
    assert placed(job_dir) == []
    refute File.exists?(Path.join(root, "escape"))
    refute File.exists?(Path.join(Path.dirname(Attachments.source_dir(job_dir)), "escape"))
  end

  test "an entry that is not shaped as the platform makes one is refused", %{
    job_dir: job_dir,
    served: served
  } do
    for overrides <- [
          %{"key" => "job/other/transcript.jsonl"},
          %{"key" => "upload/../../x"},
          %{"version_id" => "../../x"},
          %{"token" => nil},
          %{"size" => "3"},
          %{"hash" => "md5:abc"}
        ] do
      assert Attachments.sync(job_dir, [entry(served, "x.txt", "abc", overrides)]) == ["x.txt"]
    end

    assert placed(job_dir) == []
  end

  test "two entries of one name are one path, and the first wins", %{
    job_dir: job_dir,
    served: served
  } do
    assert Attachments.sync(job_dir, [
             entry(served, "a.txt", "first"),
             entry(served, "a.txt", "second")
           ]) == []

    assert File.read!(Path.join(Attachments.source_dir(job_dir), "a.txt")) == "first"
  end

  test "a replaced symlink or directory under a name is replaced, not followed", %{
    job_dir: job_dir,
    served: served,
    root: root
  } do
    one = entry(served, "a.txt", "one")
    Attachments.sync(job_dir, [one])
    target = Path.join(Attachments.source_dir(job_dir), "a.txt")
    File.rm!(target)
    outside = Path.join(root, "outside")
    File.write!(outside, "precious")
    File.ln_s!(outside, target)

    Attachments.sync(job_dir, [one])

    assert File.read!(outside) == "precious"
    assert File.read!(target) == "one"
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(target)
  end

  describe "what the manifest says once downloads are known" do
    test "a file that failed is named as not received, with why" do
      spec = %Spec{
        job_id: "j",
        branch: "b",
        attachments: %{
          "files" => [
            %{"file" => "ok.png", "original" => "ok.png"},
            %{
              "file" => "bad.png",
              "original" => "Bad Name.png",
              "to" => "the ticket",
              "by" => "Ada",
              "at" => "now"
            }
          ],
          "not_received" => [%{"original" => "earlier.mov"}]
        }
      }

      accounted = Attachments.account(spec, ["bad.png"])

      assert [%{"file" => "ok.png"}] = accounted.attachments["files"]

      assert [%{"original" => "earlier.mov"}, %{"original" => "Bad Name.png", "why" => why}] =
               accounted.attachments["not_received"]

      assert why =~ "could not be downloaded"
      assert Attachments.account(spec, []) == spec
      assert Attachments.account(%Spec{job_id: "j", branch: "b"}, ["x"]).attachments == nil
    end

    test "prepare/3 downloads, and leaves a spec without a pool alone", %{
      root: root,
      job_id: job_id,
      served: served
    } do
      spec = %Spec{
        job_id: job_id,
        branch: "b",
        attachments: %{"files" => [%{"file" => "a.txt"}], "not_received" => []}
      }

      ok = entry(served, "a.txt", "abc")

      assert Attachments.prepare(root, spec, [ok]) == spec
      assert File.exists?(Path.join(Attachments.source_dir(Path.join(root, job_id)), "a.txt"))
      assert Attachments.prepare(root, spec, nil) == spec

      assert_raise ArgumentError, fn ->
        Attachments.prepare(root, %{spec | job_id: "../x"}, [ok])
      end
    end
  end

  describe "the folder the job sees" do
    test "is a read-only mount of the worker's own directory", %{job_dir: job_dir, root: root} do
      RecordingBind.watch(root)

      assert Attachments.start(job_dir) == :ok
      assert_receive {:bound, source, folder}
      assert source == Attachments.source_dir(job_dir)
      assert folder == Path.join(job_dir, "attachments")

      assert Attachments.refresh(job_dir) == :ok
      assert_receive {:refreshed, ^source, ^folder}

      assert Attachments.release(job_dir) == :ok
      assert_receive {:unbound, ^folder}
    end

    test "a mount that fails is a job that does not start", %{job_dir: job_dir, root: root} do
      RecordingBind.watch(root, bind: {:error, :boom})
      assert Attachments.start(job_dir) == {:error, :boom}
    end

    test "where it cannot be mounted it is a copy that refresh makes again", %{
      job_dir: job_dir,
      served: served
    } do
      assert Attachments.sync(job_dir, [entry(served, "a.txt", "one")]) == []
      assert Attachments.start(job_dir) == :ok
      folder = Path.join(job_dir, "attachments")
      assert File.read!(Path.join(folder, "a.txt")) == "one"

      assert Attachments.sync(job_dir, [entry(served, "b.txt", "two")]) == []
      assert Attachments.refresh(job_dir) == :ok
      assert File.ls!(folder) == ["b.txt"]
    end

    test "starting again releases what an earlier run left", %{job_dir: job_dir, root: root} do
      RecordingBind.watch(root)
      Attachments.start(job_dir)
      Attachments.start(job_dir)
      folder = Path.join(job_dir, "attachments")
      assert_receive {:unbound, ^folder}
    end
  end

  test "the worker's start unmounts what a killed worker left, and only under its root" do
    info = """
    36 25 0:30 / /var/lib/forge/jobs/a/attachments rw,relatime - ext4 /dev/sda1 rw
    37 25 0:31 / /var/lib/forge/jobs/a/archive rw,relatime - 9p x rw
    38 25 0:32 / /elsewhere/attachments rw,relatime - ext4 /dev/sda1 rw
    39 25 0:33 / /var/lib/forge/jobs/b/notes rw,relatime - ext4 /dev/sda1 rw
    """

    assert Attachments.sweep("/var/lib/forge/jobs", info) == 1
  end
end
