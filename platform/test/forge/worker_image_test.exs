defmodule Forge.WorkerImageTest do
  @moduledoc """
  What the platform knows of the image its release published
  (`docs/design/provisioning.md` § Putting the release's image into an account).
  """

  use ExUnit.Case, async: false

  import Forge.ImageBuildsFixtures

  alias Forge.WorkerImage

  describe "release/0" do
    test "is what the platform was built knowing" do
      put_release()

      assert %{build: "abcdef123456", version: "0.20.0", protocol: 1, raw_size: 4096} =
               WorkerImage.release()
    end

    test "is nil on a node that does not know it" do
      put_release(nil)
      assert WorkerImage.release() == nil
    end

    # The values end up in a script a provider shows in its console, so a value that is not the
    # shape it should have is no release at all rather than something to quote.
    test "is nil when any value is not the shape it should have" do
      for bad <- [
            %{"build" => "short"},
            %{"build" => "ABCDEF123456"},
            %{"version" => "not-a-version"},
            %{"repository" => "ghcr.io/o/x'; rm -rf /; '"},
            %{"repository" => "has space/x"},
            %{"digest" => "sha256:abc"},
            %{"digest" => "md5:" <> String.duplicate("a", 64)},
            %{"raw_sha256" => String.duplicate("g", 64)},
            %{"raw_sha256" => String.duplicate("b", 63)},
            %{"raw_sha256" => String.duplicate("b", 65)},
            %{"raw_size" => "0"},
            %{"raw_size" => "12 && poweroff"}
          ] do
        put_release(bad)
        assert WorkerImage.release() == nil, "accepted #{inspect(bad)}"
      end
    end
  end

  describe "holds?/3" do
    @v "0.20.0"

    test "a marked snapshot of the build is held, and nothing else of the build alone is" do
      assert WorkerImage.holds?([%{build: "a", current: true}], "a", @v)
      refute WorkerImage.holds?([%{build: "a", current: false}], "a", @v)
      refute WorkerImage.holds?([%{build: "a"}], "a", @v)
      refute WorkerImage.holds?([%{build: "b", current: true}], "a", @v)
      refute WorkerImage.holds?([], "a", @v)
    end

    # A snapshot a person marked stays what `latest` uses until the account next lacks
    # the platform's build, so ours being present and unmarked beside it is not a reason to build.
    test "ours present and unmarked is held when somebody's snapshot is marked" do
      ours = %{build: "a", current: false}
      assert WorkerImage.holds?([ours, %{build: "h", current: true}], "a", @v)
      # `bin/hetzner-image` labels a build and a protocol and no version.
      assert WorkerImage.holds?([ours, %{build: "h", current: true, version: nil}], "a", @v)
      assert WorkerImage.holds?([ours, %{build: "h", current: true, version: "0.20.0"}], "a", @v)
    end

    # The stray of a build that ended before its mark was set, in an account whose `latest` still
    # points at an older release: the mark is the platform's to move.
    test "ours present and unmarked is not held when the marked one is an older release" do
      ours = %{build: "a", current: false}
      refute WorkerImage.holds?([ours, %{build: "o", current: true, version: "0.19.0"}], "a", @v)
    end

    test "somebody's marked snapshot is no reason to hold a build that is not there" do
      refute WorkerImage.holds?([%{build: "h", current: true}], "a", @v)
    end
  end

  describe "newer_in?/2" do
    test "compares versions as versions" do
      assert WorkerImage.newer_in?([%{version: "0.10.0"}], "0.9.0")
      refute WorkerImage.newer_in?([%{version: "0.9.0"}], "0.10.0")
      refute WorkerImage.newer_in?([%{version: "0.9.0"}], "0.9.0")
    end

    test "an unlabelled snapshot is never newer" do
      refute WorkerImage.newer_in?([%{id: "x"}, %{version: nil}], "0.0.1")
    end
  end

  describe "published?/0" do
    test "asks the registry anonymously, for the digest the platform was built knowing" do
      test = self()
      put_release()
      WorkerImage.forget()
      previous = Application.get_env(:forge, WorkerImage)

      Application.put_env(
        :forge,
        WorkerImage,
        Keyword.put(previous, :request, fn method, url, token ->
          send(test, {:asked, method, url, token})
          if method == :get, do: {:ok, 200, %{"token" => "anon"}}, else: {:ok, 307, ""}
        end)
      )

      assert WorkerImage.published?()
      assert_receive {:asked, :get, "https://ghcr.io/token?" <> query, nil}
      assert query =~ "scope=repository:owner/forge-worker-image:pull"
      assert_receive {:asked, :head, url, "anon"}

      assert url ==
               "https://ghcr.io/v2/owner/forge-worker-image/blobs/sha256:" <>
                 String.duplicate("a", 64)
    end

    test "remembers the answer for a minute, and forgets on request" do
      put_release()
      test = self()
      previous = Application.get_env(:forge, WorkerImage)

      Application.put_env(
        :forge,
        WorkerImage,
        Keyword.put(previous, :request, fn method, _url, _token ->
          send(test, {:asked, method})
          if method == :get, do: {:ok, 200, %{"token" => "t"}}, else: {:ok, 200, ""}
        end)
      )

      assert WorkerImage.published?()
      assert WorkerImage.published?()
      assert_received {:asked, :get}
      refute_received {:asked, :get}

      WorkerImage.forget()
      assert WorkerImage.published?()
      assert_received {:asked, :get}
    end

    test "asks again once the minute is up" do
      put_release()
      WorkerImage.forget()
      assert WorkerImage.published?()
      assert {_at, true} = :persistent_term.get({WorkerImage, :published})

      # An answer from a minute ago that said no is not believed any longer.
      :persistent_term.put(
        {WorkerImage, :published},
        {System.monotonic_time(:millisecond) - 61_000, false}
      )

      assert WorkerImage.published?()

      # And one from a moment ago is.
      :persistent_term.put(
        {WorkerImage, :published},
        {System.monotonic_time(:millisecond), false}
      )

      refute WorkerImage.published?()
    end

    test "is false when the blob is not there, when there is no token and without a release" do
      put_release(%{}, false)
      refute WorkerImage.published?()

      put_release(nil)
      refute WorkerImage.published?()
    end
  end
end
