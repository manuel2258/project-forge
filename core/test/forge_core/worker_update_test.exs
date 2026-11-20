defmodule ForgeCore.WorkerUpdateTest do
  @moduledoc """
  What both sides of an update agree on, and what each does with a report it was sent
  (`docs/design/worker-tier.md` § Updating a permanent machine).
  """

  use ExUnit.Case, async: true

  alias ForgeCore.WorkerUpdate

  @target %{
    "build" => "8rh57whmgk6m",
    "version" => "0.23.0",
    "repository" => "ghcr.io/example/forge-worker-image",
    "digest" => "sha256:" <> String.duplicate("a", 64),
    "raw_sha256" => String.duplicate("b", 64),
    "raw_size" => 1_234_567
  }

  describe "the limits" do
    test "three tries, and 15 minutes then an hour between them" do
      assert WorkerUpdate.tries() == 3
      assert WorkerUpdate.retry_after_ms(1) == 15 * 60_000
      assert WorkerUpdate.retry_after_ms(2) == 60 * 60_000
      assert WorkerUpdate.retry_after_ms(3) == nil
    end

    test "fifteen minutes on trial and thirty to pause" do
      assert WorkerUpdate.trial_ms() == 15 * 60_000
      assert WorkerUpdate.pause_ms() == 30 * 60_000
    end
  end

  describe "target/1" do
    test "accepts what a release publishes, from either key type" do
      assert {:ok, @target} = WorkerUpdate.target(@target)

      atoms = Map.new(@target, fn {key, value} -> {String.to_atom(key), value} end)
      assert {:ok, @target} = WorkerUpdate.target(atoms)
    end

    test "refuses each field that is not the shape a release has" do
      for {key, bad} <- [
            {"build", "short"},
            {"build", "UPPERCASE123"},
            {"build", 12},
            {"version", "latest"},
            {"repository", "https://evil.example/x"},
            {"repository", "ghcr.io/Example/UP"},
            {"digest", "sha256:abc"},
            {"digest", "md5:" <> String.duplicate("a", 32)},
            {"raw_sha256", String.duplicate("g", 64)},
            {"raw_size", 0},
            {"raw_size", "12"}
          ] do
        assert WorkerUpdate.target(%{@target | key => bad}) == :error, "#{key}: #{inspect(bad)}"
      end
    end

    test "refuses a missing field and anything that is not a map" do
      assert WorkerUpdate.target(Map.delete(@target, "digest")) == :error
      assert WorkerUpdate.target(nil) == :error
      assert WorkerUpdate.target("x") == :error
    end
  end

  describe "normalise/1" do
    test "keeps the known keys with the right type" do
      report = %{
        "step" => "pausing",
        "target_build" => "8rh57whmgk6m",
        "target_version" => "0.23.0",
        "reason" => "no room",
        "attempt" => 2,
        "next_at" => 1_700_000_000_000,
        "at" => 1_699_999_000_000,
        "jobs" => ["a", "b"],
        "chats" => ["c"],
        "automatic" => true,
        "unable" => "layout",
        "extra" => "dropped"
      }

      assert WorkerUpdate.normalise(report) == Map.delete(report, "extra")
    end

    test "leaves out a value of the wrong type rather than raising on it" do
      report = %{
        "step" => %{"a" => 1},
        "reason" => ["x"],
        "attempt" => "3",
        "next_at" => -1,
        "jobs" => "nope",
        "chats" => [1, %{}, "ok"],
        "automatic" => "yes",
        "unable" => "because",
        "target_build" => 12
      }

      assert WorkerUpdate.normalise(report) == %{"chats" => ["ok"]}
    end

    test "leaves out a step it does not know, and text that is not text" do
      assert WorkerUpdate.normalise(%{"step" => "exploding"}) == %{}
      assert WorkerUpdate.normalise(%{"reason" => <<255, 254>>}) == %{}
    end

    test "clips what the machine says" do
      long = String.duplicate("é", 5_000)
      assert %{"reason" => reason} = WorkerUpdate.normalise(%{"reason" => long})
      assert String.length(reason) == 500
    end

    test "caps how many ids it keeps" do
      ids = for n <- 1..600, do: "job-#{n}"
      assert %{"jobs" => kept} = WorkerUpdate.normalise(%{"jobs" => ids})
      assert length(kept) == 500
    end

    test "keeps a count up to 2^53 and no further, which is the last a float holds exactly" do
      limit = 9_007_199_254_740_992
      assert WorkerUpdate.normalise(%{"attempt" => limit}) == %{"attempt" => limit}
      assert WorkerUpdate.normalise(%{"attempt" => limit + 1}) == %{}
      assert WorkerUpdate.normalise(%{"next_at" => 1_000_000_000_000_000_000_000}) == %{}
    end

    test "keeps only ids that are text, clipped, and drops one that is not valid UTF-8" do
      long = String.duplicate("é", 1_000)

      assert %{"jobs" => [clipped, "ok"]} =
               WorkerUpdate.normalise(%{"jobs" => [long, <<255, 254>>, "ok", 7]})

      assert String.length(clipped) == 200
    end

    test "is empty for anything that is not a map" do
      assert WorkerUpdate.normalise(nil) == %{}
      assert WorkerUpdate.normalise([1]) == %{}
    end
  end

  describe "normalise_disk/1" do
    test "keeps each kind and each rule's last run" do
      report = %{
        "at" => 10,
        "kinds" => %{"nix_store" => 5, "volumes" => 4, "seeds" => 3, "jobs" => 2, "rest" => 1},
        "cleanups" => %{"volumes" => %{"at" => 9, "freed" => 8}}
      }

      assert WorkerUpdate.normalise_disk(report) == report
    end

    test "drops a kind or a rule whose value is not a count, and unknown ones" do
      report = %{
        "at" => 10,
        "kinds" => %{"nix_store" => "5", "volumes" => 4, "secrets" => 9},
        "cleanups" => %{
          "volumes" => %{"at" => "9", "freed" => 8},
          "seeds" => %{"at" => 9, "freed" => 8},
          "everything" => %{"at" => 1, "freed" => 1}
        }
      }

      assert WorkerUpdate.normalise_disk(report) == %{
               "at" => 10,
               "kinds" => %{"volumes" => 4},
               "cleanups" => %{"seeds" => %{"at" => 9, "freed" => 8}}
             }
    end

    test "is empty when no kind is usable" do
      assert WorkerUpdate.normalise_disk(%{"at" => 1, "kinds" => %{"x" => 1}}) == %{}
      assert WorkerUpdate.normalise_disk(%{"kinds" => "big"}) == %{}
      assert WorkerUpdate.normalise_disk("x") == %{}
    end
  end
end
