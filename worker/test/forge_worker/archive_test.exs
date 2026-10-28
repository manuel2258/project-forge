defmodule ForgeWorker.ArchiveTest.LeavingSlice do
  @moduledoc "`Slice.Direct`, saying when it is asked to hand a job's files back."

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  def leave(_owner, paths) do
    send(Application.fetch_env!(:forge_worker, :archive_test_pid), {:left, paths})
    :ok
  end

  @impl ForgeWorker.Slice
  defdelegate prepare(opts), to: ForgeWorker.Slice.Direct
  @impl ForgeWorker.Slice
  defdelegate wrap(executable, args, context), to: ForgeWorker.Slice.Direct
  @impl ForgeWorker.Slice
  defdelegate cleanup(context), to: ForgeWorker.Slice.Direct
  @impl ForgeWorker.Slice
  defdelegate memory(context), to: ForgeWorker.Slice.Direct
  @impl ForgeWorker.Slice
  defdelegate ended(context, output), to: ForgeWorker.Slice.Direct
  @impl ForgeWorker.Slice
  defdelegate probe(), to: ForgeWorker.Slice.Direct
  @impl ForgeWorker.Slice
  defdelegate enter(job_id), to: ForgeWorker.Slice.Direct
  @impl ForgeWorker.Slice
  defdelegate own(owner, paths), to: ForgeWorker.Slice.Direct
  @impl ForgeWorker.Slice
  defdelegate run_as(owner, executable, args), to: ForgeWorker.Slice.Direct
end

defmodule ForgeWorker.ArchiveTest do
  @moduledoc """
  The archive as a job directory has it (`docs/design/archive.md` § The worker's side): made once
  the directory is prepared, gone with the job, and gone before the files are handed back.
  """

  # Application environment: the mount in use and who hears of it.
  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeWorker.{Archive, RecordingMount, Slice}

  @grant %{url: "http://platform.test", token: "secret-token"}

  setup do
    Application.put_env(:forge_worker, :archive_mount, RecordingMount)
    Application.put_env(:forge_worker, :archive_test_pid, self())

    on_exit(fn ->
      for key <- [
            :archive_mount,
            :archive_test_pid,
            :archive_test_mount,
            :archive_test_serves,
            :platform_url
          ],
          do: Application.delete_env(:forge_worker, key)
    end)

    root = tmp_dir("archive")
    job_dir = Path.join(root, "job")
    File.mkdir_p!(job_dir)
    %{job_dir: job_dir}
  end

  test "it is a folder beside the rest, named once", %{job_dir: job_dir} do
    assert Archive.dir(job_dir) == Path.join(job_dir, "archive")
  end

  test "starting serves a socket in a private directory of its own and mounts it", context do
    assert Archive.start(context.job_dir, @grant, "j") == :ok

    folder = Archive.dir(context.job_dir)
    assert_received {:mounted, socket, ^folder}
    assert File.exists?(socket)
    assert File.dir?(folder)
    assert File.stat!(Path.dirname(socket)).mode |> Bitwise.band(0o777) == 0o700

    assert String.starts_with?(
             Path.dirname(socket),
             Path.join(System.tmp_dir!(), "forge-archive-")
           )

    # Short enough for any root: a unix socket's path is at most 107 bytes.
    assert byte_size(socket) < 80
  end

  test "releasing unmounts, stops the server and takes the socket away; again is nothing",
       context do
    :ok = Archive.start(context.job_dir, @grant, "j")
    assert_received {:mounted, socket, _}
    flush()
    assert Archive.release(context.job_dir) == :ok

    folder = Archive.dir(context.job_dir)
    assert_received {:unmounted, ^folder}
    refute File.exists?(socket)
    refute File.exists?(Path.dirname(socket))

    assert Archive.release(context.job_dir) == :ok
    assert Archive.release(Path.join(context.job_dir, "never-started")) == :ok
  end

  test "a resume starts over: what was mounted is released first, and the socket is new",
       context do
    :ok = Archive.start(context.job_dir, @grant, "j")
    assert_received {:mounted, first, _}
    flush()
    :ok = Archive.start(context.job_dir, @grant, "j")

    folder = Archive.dir(context.job_dir)
    assert_received {:unmounted, ^folder}
    assert_received {:mounted, second, ^folder}
    assert second != first
    assert File.exists?(second)
    refute File.exists?(first)
  end

  test "a mount that fails is an error and leaves no server", context do
    Application.put_env(:forge_worker, :archive_test_mount, {:error, :boom})

    assert Archive.start(context.job_dir, @grant, "j") == {:error, :boom}
    assert_received {:mounted, socket, _}
    refute File.exists?(socket)
    refute File.exists?(Path.dirname(socket))
  end

  test "a machine with no mount has one file saying so and no server", context do
    Application.put_env(:forge_worker, :archive_mount, ForgeWorker.Archive.Mount.None)

    assert Archive.start(context.job_dir, @grant, "j") == :ok
    assert File.ls!(Archive.dir(context.job_dir)) == ["README.md"]
    assert Registry.lookup(ForgeWorker.Job.Registry, {:archive, context.job_dir}) == []
  end

  test "handing a job's files back releases the archive first", context do
    :ok = Archive.start(context.job_dir, @grant, "j")
    flush()

    Slice.leave({Slice.Direct, %{kind: :direct, job_id: "j"}}, [context.job_dir])

    folder = Archive.dir(context.job_dir)
    assert_received {:unmounted, ^folder}
  end

  # The order is the whole reason for the change: the `chown -R` that takes a job's files back must
  # not meet a live mount, which it would walk — a download of every file, and an error on each.
  test "handing the files back releases the archive before the slice is asked to", context do
    :ok = Archive.start(context.job_dir, @grant, "j")
    flush()

    Slice.leave({ForgeWorker.ArchiveTest.LeavingSlice, %{}}, [context.job_dir])

    folder = Archive.dir(context.job_dir)
    job_dir = context.job_dir
    assert [{:unmounted, ^folder}, {:left, [^job_dir]}] = messages()
  end

  test "the grant is the platform and the job's own token, and nothing without both" do
    Application.put_env(:forge_worker, :platform_url, "http://p.test")

    assert Archive.grant(%{"git" => %{"url" => "u", "token" => "t"}}) ==
             %{url: "http://p.test", token: "t"}

    assert Archive.grant(%{"git" => %{"url" => "u"}}) == nil
    assert Archive.grant(%{"git" => %{"url" => "u", "token" => nil}}) == nil
    assert Archive.grant(%{}) == nil

    Application.delete_env(:forge_worker, :platform_url)
    System.delete_env("FORGE_PLATFORM_URL")
    assert Archive.grant(%{"git" => %{"token" => "t"}}) == nil
  end

  test "sweeping unmounts a 9p mount left under the root and nothing else", context do
    root = Path.dirname(context.job_dir)

    info = """
    41 29 0:44 / #{root}/job/archive ro - 9p x ro
    42 29 0:45 / /elsewhere/job/archive ro - 9p x ro
    43 29 0:46 / #{root}/job/other rw - ext4 /dev/x rw
    """

    assert Archive.sweep(root, info) == 1
    folder = Path.join(root, "job/archive")
    assert_received {:unmounted, ^folder}
    refute_received {:unmounted, "/elsewhere/job/archive"}
    refute_received {:unmounted, _}
  end

  defp messages do
    receive do
      message -> [message | messages()]
    after
      0 -> []
    end
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end
end
