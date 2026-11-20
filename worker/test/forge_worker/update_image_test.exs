defmodule ForgeWorker.UpdateImageTest do
  @moduledoc """
  What the image says and the worker believes about a machine's update, kept to one number each
  (`docs/design/worker-tier.md` § Updating a permanent machine). The image is Nix and the worker
  is Elixir, and nothing else would notice them drifting apart: a trial timer shorter than the
  worker's limit reverts a system the platform would still have accepted.
  """

  use ExUnit.Case, async: true

  @image Path.expand("../../../nix/worker-image.nix", __DIR__)

  test "the image's fallback timer is the trial limit ForgeCore names" do
    [_all, minutes] = Regex.run(~r/updateFallbackMinutes = (\d+);/, File.read!(@image))
    assert String.to_integer(minutes) * 60_000 == ForgeCore.WorkerUpdate.trial_ms()
    assert File.read!(@image) =~ ~s(OnBootSec = "${toString updateFallbackMinutes}min")
  end

  test "the layout the image writes is the one the worker and the script look for" do
    assert File.read!(@image) =~ ~s(environment.etc."forge/layout".text = "2\\n")

    assert File.read!(Path.expand("../../../nix/system-update.sh", __DIR__)) =~
             ~r/cat "\$layout".*= 2 \]/
  end

  test "the image points the worker at the script and the root-only directory" do
    image = File.read!(@image)
    assert image =~ ~s(FORGE_UPDATE_SCRIPT = "${systemUpdate}/bin/forge-system-update")
    assert image =~ ~s("d ${updateDir} 0700 root root -")
  end
end
