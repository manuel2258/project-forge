defmodule Forge.Provider.HetznerBuildTest do
  @moduledoc """
  The Hetzner driver's builder: the requests it sends, through the same seam as the rest of the
  driver (`docs/design/provisioning.md` § Putting the release's image into an account).

  **That a real builder writes a real disk is not proven here.** What is asserted is only what the
  shape of a request can carry, and what the first-boot script contains.
  """

  use ExUnit.Case, async: false

  alias Forge.Provider
  alias Forge.Provider.Hetzner

  @credential %{"token" => "hcloud-secret-token"}
  @source %{
    build_id: "11111111-2222-3333-4444-555555555555",
    repository: "ghcr.io/owner/forge-worker-image",
    digest: "sha256:" <> String.duplicate("a", 64),
    raw_sha256: String.duplicate("b", 64),
    raw_size: 4096
  }

  setup do
    previous = Application.get_env(:forge, Provider, [])
    on_exit(fn -> Application.put_env(:forge, Provider, previous) end)
    configure(location: "nbg1", token: nil)
    :ok
  end

  defp configure(opts) do
    current = Application.get_env(:forge, Provider, [])
    Application.put_env(:forge, Provider, Keyword.merge(current, opts))
  end

  # Answers by method and path; the request is also sent to the test, in order.
  defp serving(routes) do
    test = self()

    configure(
      request: fn method, path, token, body ->
        send(test, {:hetzner, method, path, token, body})

        route =
          Enum.find_value(routes, fn {{m, prefix}, answer} ->
            if m == method and String.starts_with?(path, prefix), do: answer
          end)

        route || {:ok, 200, %{}}
      end
    )
  end

  defp flush(acc \\ []) do
    receive do
      {:hetzner, _, _, _, _} = message -> flush([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp type(name, memory, price, opts \\ []) do
    %{
      "name" => name,
      "memory" => memory,
      "cores" => 2,
      "architecture" => Keyword.get(opts, :architecture, "x86"),
      "locations" => [
        %{
          "name" => "nbg1",
          "deprecation" => nil,
          "available" => Keyword.get(opts, :available, true)
        }
      ],
      "prices" => [%{"location" => "nbg1", "price_hourly" => %{"net" => price}}]
    }
  end

  defp types do
    {:ok, 200,
     %{
       "server_types" => [
         type("small", 2, "0.001"),
         type("arm", 8, "0.002", architecture: "arm"),
         type("pricey", 8, "0.020"),
         type("cheap4", 4, "0.005"),
         type("gone", 4, "0.001", available: false)
       ]
     }}
  end

  describe "start_build/2" do
    test "creates a builder from a stock image, labelled as a builder, with no secret in it" do
      serving([
        {{:get, "/server_types"}, types()},
        {{:get, "/servers?"}, {:ok, 200, %{"servers" => []}}},
        {{:post, "/servers"}, {:ok, 201, %{"server" => %{"id" => 77}, "root_password" => "pw"}}}
      ])

      assert {:ok, handle} = Hetzner.start_build(@credential, @source)
      assert handle == %{"build_id" => @source.build_id, "server_id" => "77"}

      assert_receive {:hetzner, :post, "/servers", "hcloud-secret-token", body}
      assert body.name == "forge-builder-" <> @source.build_id
      assert body.image == "debian-12"
      assert body.server_type == "cheap4"
      assert body.start_after_create
      assert body.labels["forge"] == "image-builder"
      refute Map.has_key?(body, :ssh_keys)

      # The provider shows this script in its console: the four values and nothing else.
      assert body.user_data =~ "REPOSITORY='ghcr.io/owner/forge-worker-image'"
      assert body.user_data =~ "DIGEST='#{@source.digest}'"
      assert body.user_data =~ "RAW_SHA256='#{@source.raw_sha256}'"
      assert body.user_data =~ "RAW_SIZE='4096'"
      refute body.user_data =~ ~r/@[A-Z_]+@/
      refute inspect(body) =~ "hcloud-secret-token"
      refute inspect(body) =~ "pw"
      refute body.user_data =~ "http://"
    end

    test "finds the builder it already made rather than making a second" do
      serving([
        {{:get, "/servers?"}, {:ok, 200, %{"servers" => [%{"id" => 5}]}}}
      ])

      assert {:ok, %{"server_id" => "5"}} = Hetzner.start_build(@credential, @source)
      assert_receive {:hetzner, :get, "/servers?" <> query, _, _}
      assert query =~ "name=forge-builder-" <> @source.build_id
      assert query =~ "label_selector=forge%3Dimage-builder"
      refute_receive {:hetzner, :post, _, _, _}
    end

    test "says so when no server type fits, rather than guessing" do
      serving([
        {{:get, "/server_types"}, {:ok, 200, %{"server_types" => [type("small", 2, "0.001")]}}},
        {{:get, "/servers?"}, {:ok, 200, %{"servers" => []}}}
      ])

      assert {:error, {:hetzner, message}} = Hetzner.start_build(@credential, @source)
      assert message =~ "no x86 server type"
    end
  end

  describe "a builder is never a worker" do
    test "list and find ask for workers only" do
      serving([{{:get, "/servers"}, {:ok, 200, %{"servers" => []}}}])

      Hetzner.list(@credential)
      Hetzner.find("w-1", @credential)

      assert_receive {:hetzner, :get, "/servers?" <> list, _, _}
      assert list =~ "label_selector=forge%3Dworker"
      assert_receive {:hetzner, :get, "/servers?" <> find, _, _}
      assert find =~ "label_selector=forge%3Dworker"
      refute list =~ "image-builder"
    end
  end

  describe "build_progress/2" do
    # **Off is the success signal only after the builder was seen running**: a server is off before
    # its first start, after a failed one, and when somebody powers it off from the console.
    test "a builder that was seen running and is off is ready" do
      serving([{{:get, "/servers/9"}, {:ok, 200, %{"server" => %{"status" => "off"}}}}])
      handle = %{"server_id" => "9", "seen_running" => true}
      assert {:ready, ^handle} = Hetzner.build_progress(@credential, handle)
    end

    test "a builder that is off and was never seen running is not ready" do
      serving([{{:get, "/servers/9"}, {:ok, 200, %{"server" => %{"status" => "off"}}}}])
      handle = %{"server_id" => "9"}
      assert {:running, ^handle} = Hetzner.build_progress(@credential, handle)
    end

    test "seeing a builder running is remembered in the handle" do
      serving([{{:get, "/servers/9"}, {:ok, 200, %{"server" => %{"status" => "running"}}}}])

      assert {:running, %{"seen_running" => true, "server_id" => "9"}} =
               Hetzner.build_progress(@credential, %{"server_id" => "9"})
    end

    test "a builder still starting is running" do
      serving([{{:get, "/servers/9"}, {:ok, 200, %{"server" => %{"status" => "initializing"}}}}])
      handle = %{"server_id" => "9"}
      assert {:running, ^handle} = Hetzner.build_progress(@credential, handle)
    end

    test "a builder that is gone is a failure" do
      serving([{{:get, "/servers/9"}, {:ok, 404, %{}}}])

      assert {:failed, "the builder server is gone"} =
               Hetzner.build_progress(@credential, %{"server_id" => "9"})
    end

    test "a request that got no answer is still running, not failed" do
      configure(request: fn _method, _path, _token, _body -> {:error, "timeout"} end)
      handle = %{"server_id" => "9"}
      assert {:running, ^handle} = Hetzner.build_progress(@credential, handle)
      image = %{"server_id" => "9", "image_id" => "3"}
      assert {:running, ^image} = Hetzner.build_progress(@credential, image)
    end

    test "a snapshot still being made is running, and nothing is marked or deleted" do
      serving([{{:get, "/images/3"}, {:ok, 200, %{"image" => %{"status" => "creating"}}}}])
      handle = %{"server_id" => "9", "image_id" => "3", "current" => true}
      assert {:running, ^handle} = Hetzner.build_progress(@credential, handle)
      refute_receive {:hetzner, :delete, _, _, _}
      refute_receive {:hetzner, :put, _, _, _}
    end

    @available {:ok, 200,
                %{
                  "image" => %{
                    "status" => "available",
                    "labels" => %{"forge-worker-build" => "b"}
                  }
                }}
    @handle %{
      "server_id" => "9",
      "image_id" => "3",
      "current" => true,
      "version" => "0.20.0"
    }

    # The mark is set when the snapshot is available — `latest` would otherwise resolve to one
    # still being made — and moves before the builder goes, as `bin/hetzner-image` does it, so a
    # run cut short leaves two marked rather than none; the others keep their other labels.
    test "an available snapshot is marked, the others unmarked, then the builder deleted" do
      others = [
        %{
          "id" => 8,
          "labels" => %{
            "forge-worker-current" => "1",
            "forge-worker-build" => "old",
            "forge-worker-version" => "0.19.0",
            "mine" => "y"
          }
        }
      ]

      serving([
        {{:get, "/images/3"}, @available},
        {{:get, "/images?"}, {:ok, 200, %{"images" => others}}},
        {{:put, "/images/"}, {:ok, 200, %{}}},
        {{:delete, "/servers/9"}, {:ok, 200, %{}}}
      ])

      assert {:built, "3"} = Hetzner.build_progress(@credential, @handle)
      sent = flush()

      assert {:hetzner, :get, "/images?" <> query, _, _} =
               Enum.find(sent, &match?({:hetzner, :get, "/images?" <> _, _, _}, &1))

      assert query =~ "label_selector=forge-worker-current"

      assert {:hetzner, :put, _, _, %{labels: mine}} =
               Enum.find(sent, &match?({:hetzner, :put, "/images/3", _, _}, &1))

      assert mine == %{"forge-worker-build" => "b", "forge-worker-current" => "1"}

      assert {:hetzner, :put, _, _, %{labels: theirs}} =
               Enum.find(sent, &match?({:hetzner, :put, "/images/8", _, _}, &1))

      assert theirs == %{
               "forge-worker-build" => "old",
               "forge-worker-version" => "0.19.0",
               "mine" => "y"
             }

      # In that order: ours marked, the others unmarked, the builder deleted.
      assert [{:put, "/images/3"}, {:put, "/images/8"}, {:delete, "/servers/9"}] =
               for(
                 {:hetzner, method, path, _, _} <- sent,
                 method in [:put, :delete],
                 do: {method, path}
               )
    end

    # The same version is another credential's snapshot of this very release (criterion 12): it does
    # not block the mark.
    test "a marked snapshot of the same version does not block the mark" do
      others = [
        %{
          "id" => 8,
          "labels" => %{"forge-worker-current" => "1", "forge-worker-version" => "0.20.0"}
        }
      ]

      serving([
        {{:get, "/images/3"}, @available},
        {{:get, "/images?"}, {:ok, 200, %{"images" => others}}},
        {{:put, "/images/"}, {:ok, 200, %{}}},
        {{:delete, "/servers/9"}, {:ok, 200, %{}}}
      ])

      assert {:built, "3"} = Hetzner.build_progress(@credential, @handle)
      assert_receive {:hetzner, :put, "/images/3", _, %{labels: %{"forge-worker-current" => "1"}}}
    end

    # Not built unmarked: an unreadable listing is tried again, as a failed mark is.
    test "a listing that cannot be read keeps the build running, and the builder alive" do
      serving([
        {{:get, "/images/3"}, @available},
        {{:get, "/images?"}, {:ok, 500, %{"error" => %{"message" => "down"}}}}
      ])

      assert {:running, @handle} = Hetzner.build_progress(@credential, @handle)
      refute_receive {:hetzner, :delete, _, _, _}
      refute_receive {:hetzner, :put, _, _, _}
    end

    # Another node on the same project may have marked a newer release's snapshot since this build
    # began (criterion 21): nothing is moved, and the build still ends.
    test "a newer release's mark is left alone and ours is not set" do
      others = [
        %{
          "id" => 8,
          "labels" => %{"forge-worker-current" => "1", "forge-worker-version" => "0.21.0"}
        }
      ]

      serving([
        {{:get, "/images/3"}, @available},
        {{:get, "/images?"}, {:ok, 200, %{"images" => others}}},
        {{:delete, "/servers/9"}, {:ok, 200, %{}}}
      ])

      assert {:built, "3"} = Hetzner.build_progress(@credential, @handle)
      refute_receive {:hetzner, :put, _, _, _}
      assert_receive {:hetzner, :delete, "/servers/9", _, _}
    end

    test "a snapshot made without the mark moves no mark" do
      serving([
        {{:get, "/images/3"}, @available},
        {{:delete, "/servers/9"}, {:ok, 200, %{}}}
      ])

      assert {:built, "3"} = Hetzner.build_progress(@credential, %{@handle | "current" => false})
      refute_receive {:hetzner, :get, "/images?" <> _, _, _}
      refute_receive {:hetzner, :put, _, _, _}
      assert_receive {:hetzner, :delete, "/servers/9", _, _}
    end

    # Not built until the builder is gone, and not until the mark is set: each is tried again.
    test "a mark that could not be set keeps the build running and the builder alive" do
      serving([
        {{:get, "/images/3"}, @available},
        {{:get, "/images?"}, {:ok, 200, %{"images" => []}}},
        {{:put, "/images/3"}, {:ok, 500, %{}}}
      ])

      assert {:running, @handle} = Hetzner.build_progress(@credential, @handle)
      refute_receive {:hetzner, :delete, _, _, _}
    end

    test "a builder that could not be deleted keeps the build running" do
      serving([
        {{:get, "/images/3"}, @available},
        {{:get, "/images?"}, {:ok, 200, %{"images" => []}}},
        {{:put, "/images/3"}, {:ok, 200, %{}}},
        {{:delete, "/servers/9"}, {:ok, 500, %{"error" => %{"message" => "locked"}}}}
      ])

      assert {:running, @handle} = Hetzner.build_progress(@credential, @handle)
    end
  end

  describe "snapshot_build/3" do
    @labels %{build: "abcdef123456", version: "0.20.0", protocol: 1, current: true}
    @seen %{"server_id" => "9", "seen_running" => true}

    # The mark is not here: it is set when the snapshot is available (`build_progress/2`).
    test "labels the snapshot the way bin/hetzner-image does, with the version beside them" do
      serving([
        {{:get, "/servers/9"}, {:ok, 200, %{"server" => %{"status" => "off"}}}},
        {{:post, "/servers/9/actions/create_image"}, {:ok, 201, %{"image" => %{"id" => 31}}}}
      ])

      assert {:ok, %{"image_id" => "31", "current" => true, "version" => "0.20.0"}} =
               Hetzner.snapshot_build(@credential, @seen, @labels)

      assert_receive {:hetzner, :post, _, _, body}
      assert body.type == "snapshot"

      assert body.labels == %{
               "forge-worker-build" => "abcdef123456",
               "forge-worker-protocol" => "1",
               "forge-worker-version" => "0.20.0"
             }
    end

    # A snapshot of a half-written disk is what the whole signal exists to prevent.
    test "never snapshots a builder that is still running" do
      serving([{{:get, "/servers/9"}, {:ok, 200, %{"server" => %{"status" => "running"}}}}])

      assert {:error, {:hetzner, "the builder is running"}} =
               Hetzner.snapshot_build(@credential, @seen, @labels)

      refute_receive {:hetzner, :post, _, _, _}
    end

    test "never snapshots a builder that was never seen running, though it is off" do
      serving([{{:get, "/servers/9"}, {:ok, 200, %{"server" => %{"status" => "off"}}}}])

      assert {:error, {:hetzner, "the builder was never seen running"}} =
               Hetzner.snapshot_build(@credential, %{"server_id" => "9"}, @labels)

      refute_receive {:hetzner, :post, _, _, _}
    end
  end

  describe "discard_build/2" do
    test "a builder already gone is success" do
      serving([{{:delete, "/servers/9"}, {:ok, 404, %{}}}])
      assert :ok = Hetzner.discard_build(@credential, %{"server_id" => "9"})
    end

    test "a handle with no id finds its builder by name" do
      serving([
        {{:get, "/servers?"}, {:ok, 200, %{"servers" => [%{"id" => 5}]}}},
        {{:delete, "/servers/5"}, {:ok, 200, %{}}}
      ])

      assert :ok = Hetzner.discard_build(@credential, %{"build_id" => @source.build_id})
      assert_receive {:hetzner, :delete, "/servers/5", _, _}
    end
  end

  describe "sweep_builders/2" do
    test "deletes the builders past the limit and no other" do
      old = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
      young = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()

      serving([
        {{:get, "/servers?"},
         {:ok, 200,
          %{
            "servers" => [
              %{"id" => 1, "created" => old},
              %{"id" => 2, "created" => young},
              %{"id" => 3, "created" => "not a date"},
              %{"id" => 4}
            ]
          }}},
        {{:delete, "/servers/"}, {:ok, 200, %{}}}
      ])

      assert :ok = Hetzner.sweep_builders(@credential, 30 * 60 * 1000)
      assert_receive {:hetzner, :get, "/servers?" <> query, _, _}
      assert query =~ "label_selector=forge%3Dimage-builder"
      assert_receive {:hetzner, :delete, "/servers/1", _, _}
      refute_receive {:hetzner, :delete, _, _, _}
    end
  end

  describe "images/1 reads the version" do
    test "only a label that parses as a version" do
      images = [
        %{"id" => 1, "labels" => %{"forge-worker-version" => "0.20.0"}},
        %{"id" => 2, "labels" => %{"forge-worker-version" => "banana"}},
        %{"id" => 3, "labels" => %{}}
      ]

      serving([{{:get, "/images?"}, {:ok, 200, %{"images" => images}}}])
      assert {:ok, listed} = Hetzner.images(@credential)
      assert Map.new(listed, &{&1.id, &1.version}) == %{"1" => "0.20.0", "2" => nil, "3" => nil}
    end
  end

  test "only a driver that implements the callbacks builds" do
    assert Provider.builds?("hetzner")
    assert Provider.builds?("fake")
    refute Provider.builds?("local")
    refute Provider.builds?("nowhere")
  end
end
