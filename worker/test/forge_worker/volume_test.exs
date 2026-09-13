defmodule ForgeWorker.VolumeTest do
  @moduledoc """
  The volume layer, as far as a machine without btrfs can check it: `Volume.Copy`, which is
  correct without the sharing, and the argv `Volume.Btrfs` builds. That a snapshot costs
  nothing until it is written to is btrfs's claim, not this suite's — M2 measured it
  (`docs/measurements.md`) and the worker image is where it is in force.
  """

  use ExUnit.Case, async: true

  alias ForgeWorker.Volume

  @tag :tmp_dir
  test "a copy volume is a whole tree of its own", %{tmp_dir: tmp_dir} do
    seed = Path.join(tmp_dir, "seed")
    job = Path.join(tmp_dir, "jobs/one")

    assert :ok = Volume.Copy.create(seed)
    File.write!(Path.join(seed, "shared.txt"), "from the seed\n")
    File.mkdir_p!(Path.join(seed, "build"))
    File.write!(Path.join(seed, "build/warm.o"), "already compiled\n")

    assert :ok = Volume.Copy.snapshot(seed, job)

    # Everything the seed had, including what makes it warm.
    assert File.read!(Path.join(job, "shared.txt")) == "from the seed\n"
    assert File.read!(Path.join(job, "build/warm.o")) == "already compiled\n"

    # And writing in the job does not reach back into the seed, which is the whole point.
    File.write!(Path.join(job, "shared.txt"), "the job changed it\n")
    assert File.read!(Path.join(seed, "shared.txt")) == "from the seed\n"

    assert :ok = Volume.Copy.delete(job)
    refute File.exists?(job)
    assert File.exists?(seed)
  end

  @tag :tmp_dir
  test "deleting something that is not there is not a failure", %{tmp_dir: tmp_dir} do
    assert :ok = Volume.Copy.delete(Path.join(tmp_dir, "never-existed"))
  end

  @tag :tmp_dir
  test "recreate leaves an empty volume whatever was there", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "half-fetched")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "partial.tar"), "half a seed")

    assert :ok = Volume.recreate(Volume.Copy, path)
    assert File.ls!(path) == []
  end

  test "the default is the one a machine without btrfs can run" do
    assert Volume.impl() == Volume.Copy
  end
end
