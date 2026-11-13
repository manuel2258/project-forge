defmodule Forge.WorkersHarnessesTest do
  @moduledoc """
  Which harnesses a machine offers, and which jobs that lets it take
  (`docs/design/worker-channel.md` § Protocol 11).
  """

  use Forge.DataCase, async: true

  alias Forge.Workers
  alias Forge.Workers.Worker

  @claude %{"driver" => "claude_code", "credential" => "per_job", "version" => "2.1.0"}
  @codex %{"driver" => "codex", "credential" => "per_job", "version" => "0.46.0"}

  describe "runs?/2" do
    test "a machine that lists what it offers takes the jobs of each, and of nothing else" do
      worker = %Worker{harness: @claude, harnesses: [@claude, @codex]}

      assert Workers.runs?(worker, "claude_code")
      assert Workers.runs?(worker, "codex")
      refute Workers.runs?(worker, "opencode")
    end

    test "the list is believed over the single key, in both directions" do
      assert Workers.runs?(%Worker{harness: @claude, harnesses: [@codex]}, "codex")
      refute Workers.runs?(%Worker{harness: @claude, harnesses: [@codex]}, "claude_code")
    end

    test "an offer that does not take its credential from the assignment is not an offer" do
      loose = %{"driver" => "codex", "credential" => "own"}
      refute Workers.runs?(%Worker{harnesses: [@claude, loose]}, "codex")
    end

    test "a machine that sent only the one harness offers that one, as before" do
      worker = %Worker{harness: @claude, harnesses: nil}

      assert Workers.runs?(worker, "claude_code")
      refute Workers.runs?(worker, "codex")
      assert Workers.runs?(worker, nil)
    end
  end

  describe "ready" do
    defp ready(report) do
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})

      {:ok, worker} =
        Workers.ready(worker, Map.merge(%{"memory_budget" => 1_000_000_000}, report))

      worker
    end

    test "the list is kept, and is what the machine runs" do
      worker = ready(%{"harness" => @claude, "harnesses" => [@claude, @codex]})

      assert Workers.get!(worker.id).harnesses == [@claude, @codex]
      assert Workers.runs?(Workers.get!(worker.id), "codex")
    end

    test "something that is not a list of offers is not kept" do
      for bad <- ["codex", [1, 2], %{"driver" => "codex"}] do
        worker = ready(%{"harness" => @claude, "harnesses" => bad})
        assert Workers.get!(worker.id).harnesses == nil
        refute Workers.runs?(Workers.get!(worker.id), "codex")
      end
    end
  end
end
