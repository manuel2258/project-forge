defmodule Forge.Provider.HetznerTest do
  @moduledoc """
  The Hetzner driver, as far as a machine with no Hetzner account can check it: the requests it
  builds, the responses it reads, and the four ways it refuses rather than sending one.

  **That a machine boots from these is not proven here and the module says so.**
  `docs/design/worker-tier.md` § What the operator's machine settled is the standing warning —
  in every case the tests against the fakes passed and the real thing did not — so what is
  asserted is only what the shape of a request can carry.
  """

  use ExUnit.Case, async: false

  alias Forge.Provider
  alias Forge.Provider.Hetzner

  @opts %{
    worker_id: "w-1",
    token: "worker-token",
    platform_url: "https://forge.example",
    size: "cpx32",
    credential: %{"token" => "hcloud-abc"}
  }

  setup do
    previous = Application.get_env(:forge, Provider, [])
    on_exit(fn -> Application.put_env(:forge, Provider, previous) end)
    :ok
  end

  # Drives the seam: records what the driver asked for and answers with what a test wants.
  defp answering(status, body) do
    test = self()

    configure(
      request: fn method, path, token, request_body ->
        send(test, {:hetzner, method, path, token, request_body})
        {:ok, status, body}
      end
    )
  end

  defp configure(opts) do
    current = Application.get_env(:forge, Provider, [])
    Application.put_env(:forge, Provider, Keyword.merge(current, opts))
  end

  describe "creating a machine" do
    setup do
      configure(image: "snapshot-42", location: "nbg1", token: nil)
      :ok
    end

    test "the server carries the same bytes a local machine gets on a disk" do
      answering(201, %{
        "server" => %{"id" => 5, "public_net" => %{"ipv4" => %{"ip" => "1.2.3.4"}}}
      })

      assert {:ok, %{provider_id: "5", address: "1.2.3.4"}} = Hetzner.create(@opts)

      assert_receive {:hetzner, :post, "/servers", "hcloud-abc", body}
      assert body.server_type == "cpx32"
      assert body.image == "snapshot-42"
      assert body.location == "nbg1"

      # A server created and not started is a machine that bills and never boots — the worker
      # never dials, the row sits in `creating`, and nothing says why.
      assert body.start_after_create == true

      # The label is how `list/1` tells a forge machine from one of the operator's own, which
      # is what makes a leak answerable without heuristics.
      assert body.labels == %{"forge" => "worker"}

      # The identity route `worker-tier.md` § How a machine learns what it is chose: the image
      # reads Hetzner's metadata endpoint, which returns exactly what went in here.
      assert body.user_data =~ "FORGE_WORKER_ID=w-1"
      assert body.user_data =~ "FORGE_WORKER_TOKEN=worker-token"
      assert body.user_data =~ "FORGE_PLATFORM_URL=https://forge.example"
    end

    # The template's image beats the node's, which is the whole reason the column exists: two
    # templates may want different images, and an operator rolling a new one wants both to
    # exist while they move over.
    test "a template that names an image is the one booted, not the node's" do
      configure(image: "the-nodes-image", token: "t")
      answering(201, %{"server" => %{"id" => 5}})

      {:ok, _machine} = Hetzner.create(Map.put(@opts, :image, "the-templates-image"))

      assert_receive {:hetzner, :post, _path, _token, body}
      assert body.image == "the-templates-image"
    end

    # And a template naming none falls back rather than failing, which is what every template
    # made before the column does.
    test "a template naming none falls back to the node's" do
      configure(image: "the-nodes-image", token: "t")
      answering(201, %{"server" => %{"id" => 5}})

      {:ok, _machine} = Hetzner.create(Map.delete(@opts, :image))

      assert_receive {:hetzner, :post, _path, _token, body}
      assert body.image == "the-nodes-image"
    end

    test "the harness credential rides along, as it does locally" do
      answering(201, %{"server" => %{"id" => 5}})

      {:ok, _machine} =
        Hetzner.create(Map.put(@opts, :harness_env, [{"CLAUDE_CODE_OAUTH_TOKEN", "sk-x"}]))

      assert_receive {:hetzner, :post, _path, _token, body}
      assert body.user_data =~ "CLAUDE_CODE_OAUTH_TOKEN=sk-x"
    end

    # A machine with no address is still a machine: the channel is outbound, so the platform
    # never dials it and an IPv6-only or address-less answer must not fail the create.
    test "a server with no address is still created" do
      answering(201, %{"server" => %{"id" => 7}})

      assert {:ok, %{provider_id: "7", address: nil}} = Hetzner.create(@opts)
    end

    test "an ipv6-only server reports that address" do
      answering(201, %{"server" => %{"id" => 7, "public_net" => %{"ipv6" => %{"ip" => "2a01::"}}}})

      assert {:ok, %{address: "2a01::"}} = Hetzner.create(@opts)
    end

    # Hetzner's own message, not this module's guess at what went wrong. An operator reading
    # "server type cpx32 not available in nbg1" can act; "create failed" sends them nowhere.
    test "an API error is reported in Hetzner's own words" do
      answering(400, %{"error" => %{"message" => "server type not available in this location"}})

      assert {:error, {:hetzner, 400, "server type not available in this location"}} =
               Hetzner.create(@opts)
    end

    test "a transport failure is an error and not a machine" do
      configure(request: fn _m, _p, _t, _b -> {:error, "connection refused"} end)

      assert {:error, {:hetzner, "connection refused"}} = Hetzner.create(@opts)
    end
  end

  describe "what it refuses before sending anything" do
    # Each of these would otherwise be a request that fails at Hetzner, reported as a status
    # code with a message about a token when the thing that is wrong is a row or a config key.
    test "no image configured" do
      configure(image: nil, token: "t", request: &never/4)
      assert {:error, {:hetzner, "no Hetzner image configured"}} = Hetzner.create(@opts)
    end

    test "no credential at all" do
      configure(image: "snapshot-42", token: nil, request: &never/4)

      assert {:error, {:hetzner, "no Hetzner credential"}} =
               Hetzner.create(Map.delete(@opts, :credential))
    end

    # An empty token is not a credential, and the guard is `and` for exactly this: read as `or`
    # it accepts `%{"token" => ""}` and sends an unauthenticated request, which comes back as a
    # 401 about a token rather than as the configured fallback being used.
    test "a credential with an empty token falls back to the configured one" do
      configure(image: "snapshot-42", token: "from-config")
      answering(201, %{"server" => %{"id" => 9}})

      {:ok, _machine} = Hetzner.create(Map.put(@opts, :credential, %{"token" => ""}))

      assert_receive {:hetzner, :post, _path, "from-config", _body}
    end

    test "a template that names no server type" do
      configure(image: "snapshot-42", token: "t", request: &never/4)

      assert {:error, {:hetzner, "the template names no server type"}} =
               Hetzner.create(Map.delete(@opts, :size))
    end

    defp never(_method, _path, _token, _body), do: flunk("no request should have been sent")
  end

  describe "destroying a machine" do
    test "a machine that is gone is gone, not an error" do
      # **404 is success.** Treating it as a failure leaves a row nothing can retire, and a row
      # that cannot be retired holds a `max_workers` slot for ever.
      for status <- [200, 202, 204, 404] do
        configure(token: "t")
        answering(status, %{})

        assert :ok = Hetzner.destroy("5"), "#{status} should be success"
        assert_receive {:hetzner, :delete, "/servers/5", "t", nil}
      end
    end

    test "anything else is reported" do
      configure(token: "t")
      answering(500, %{"error" => %{"message" => "internal"}})

      assert {:error, {:hetzner, 500, "internal"}} = Hetzner.destroy("5")
    end

    # **The leak, at the site it was made.** `create` took the template's credential and this
    # took `token(%{})` — no credential at all — so it reached for a node-wide token that
    # per-user credentials had replaced. On a node with none it refused before sending
    # anything, `Forge.Workers` discarded the refusal, and the row was marked destroyed while
    # the machine kept running and billing. A machine is ended in the account that pays for it.
    test "the machine is destroyed with the credential it is given" do
      configure(token: nil)
      answering(200, %{})

      assert :ok = Hetzner.destroy("5", %{"token" => "the-account's"})
      assert_receive {:hetzner, :delete, "/servers/5", "the-account's", nil}
    end

    # Asking the provider about a machine is the same kind of account operation, and was the
    # same bug waiting: the class, not the instance.
    test "status is asked with the credential it is given" do
      configure(token: nil)
      answering(200, %{"server" => %{"status" => "running"}})

      assert {:ok, :running} = Hetzner.status("5", %{"token" => "the-account's"})
      assert_receive {:hetzner, :get, "/servers/5", "the-account's", nil}
    end

    # With neither a credential nor a node token there is nothing to send, and saying so is the
    # whole point: this refusal used to be thrown away by the caller.
    test "with no credential and no node token it refuses rather than sending one" do
      configure(token: nil, request: &never/4)

      assert {:error, {:hetzner, "no Hetzner credential"}} = Hetzner.destroy("5")
    end

    defp never(_method, _path, _token, _body), do: flunk("no request should have been sent")
  end

  describe "reading a machine's status" do
    test "Hetzner's states map to the three the platform has" do
      assert Hetzner.state("running") == :running

      for pending <- ~w(initializing starting rebuilding migrating) do
        assert Hetzner.state(pending) == :pending, "#{pending} should be pending"
      end

      # A machine on its way out will not take work. Calling it running keeps a row alive
      # through its own destruction.
      for gone <- ~w(deleting off stopping unknown) ++ [nil] do
        assert Hetzner.state(gone) == :gone, "#{inspect(gone)} should be gone"
      end
    end

    test "a server that is not there is gone rather than an error" do
      configure(token: "t")
      answering(404, %{"error" => %{"message" => "not found"}})

      assert {:ok, :gone} = Hetzner.status("5")
    end

    test "a live server reports its state" do
      configure(token: "t")
      answering(200, %{"server" => %{"status" => "running"}})

      assert {:ok, :running} = Hetzner.status("5")
      assert_receive {:hetzner, :get, "/servers/5", "t", nil}
    end
  end

  describe "the catalogue" do
    @types %{
      "server_types" => [
        %{
          "id" => 1,
          "name" => "cpx32",
          "cores" => 4,
          "memory" => 8.0,
          "deprecation" => nil,
          "prices" => [
            %{"location" => "fsn1", "price_hourly" => %{"net" => "0.0250"}},
            %{"location" => "nbg1", "price_hourly" => %{"net" => "0.0270"}}
          ]
        },
        %{
          "id" => 2,
          "name" => "cx23",
          "cores" => 2,
          "memory" => 4.0,
          "deprecation" => nil,
          "prices" => [
            %{"location" => "fsn1", "price_hourly" => %{"net" => "0.0090"}},
            %{"location" => "nbg1", "price_hourly" => %{"net" => "0.0090"}}
          ]
        },
        %{
          "id" => 3,
          "name" => "cx11",
          "cores" => 1,
          "memory" => 2.0,
          "deprecation" => "2024-01-01",
          "prices" => [%{"location" => "fsn1", "price_hourly" => %{"net" => "0.0050"}}]
        }
      ]
    }

    # The catalogue reads two endpoints — what exists and what this location will sell — so the
    # seam answers by path rather than giving every call the same body.
    defp answering_each(bodies) do
      test = self()

      configure(
        request: fn method, path, token, request_body ->
          send(test, {:hetzner, method, path, token, request_body})
          {:ok, 200, Map.get(bodies, path |> String.split("?") |> List.first(), %{})}
        end
      )
    end

    defp selling(location, ids) do
      %{
        "datacenters" => [
          %{
            "name" => "#{location}-dc1",
            "location" => %{"name" => location},
            "server_types" => %{"supported" => [1, 2, 3], "available" => ids}
          }
        ]
      }
    end

    defp catalogue(location, ids \\ [1, 2, 3]) do
      configure(location: location)
      answering_each(%{"/server_types" => @types, "/datacenters" => selling(location, ids)})
    end

    test "server types become shapes, smallest first" do
      catalogue("fsn1")

      assert {:ok, [small, large]} = Hetzner.shapes(%{"token" => "hcloud-abc"})

      assert small.size == "cx23"
      assert small.cores == 2
      assert small.memory == 4 * 1024 * 1024 * 1024
      assert large.size == "cpx32"
      assert large.memory == 8 * 1024 * 1024 * 1024

      assert_receive {:hetzner, :get, "/server_types?" <> _query, "hcloud-abc", nil}
    end

    # A deprecated type still runs and still lists, but a template built on one stops being
    # able to create the day Hetzner withdraws it. Offering it in a form is offering a trap.
    test "a withdrawn type is not offered" do
      catalogue("fsn1")
      configure(token: "t")

      assert {:ok, shapes} = Hetzner.shapes(nil)
      refute Enum.any?(shapes, &(&1.size == "cx11"))
    end

    # **The trap this was found as.** A node left on the driver's `fsn1` default was offered all
    # twenty-five server types while that datacenter had none orderable, so every template made
    # there failed at create with `422: unsupported location for server type`. Support is not
    # the question — `fsn1` supports `cpx11` and will not sell one — so what decides is the
    # datacenter's `available` list.
    test "a type this location cannot order is not offered" do
      catalogue("nbg1", [2])

      assert {:ok, shapes} = Hetzner.shapes(%{"token" => "t"})

      assert Enum.map(shapes, & &1.size) == ["cx23"]
      assert_receive {:hetzner, :get, "/datacenters?" <> _query, "t", nil}
    end

    # Another location's availability is not this one's, and reading the wrong datacenter would
    # rebuild the trap with an extra step.
    test "availability somewhere else is not availability here" do
      configure(location: "nbg1")

      answering_each(%{
        "/server_types" => @types,
        "/datacenters" => selling("fsn1", [1, 2])
      })

      assert {:error, {:hetzner, message}} = Hetzner.shapes(%{"token" => "t"})
      assert message =~ "nbg1"
    end

    # Saying so rather than answering with nothing: an empty catalogue leaves the form a
    # free-text box, which invites typing a machine this location cannot make and finding out
    # at create.
    test "a location with nothing orderable is an error and not an empty list" do
      catalogue("fsn1", [])

      assert {:error, {:hetzner, message}} = Hetzner.shapes(%{"token" => "t"})
      assert message =~ "no server type is orderable in fsn1"
    end

    # The price is the one for the location machines are actually made in, and net rather than
    # gross because the gross figure depends on a VAT rate this platform does not know.
    test "the price is the configured location's" do
      catalogue("nbg1")

      assert {:ok, shapes} = Hetzner.shapes(%{"token" => "t"})
      assert %{size: "cpx32", price_hourly: price, currency: "EUR"} = List.last(shapes)
      assert Decimal.equal?(price, Decimal.new("0.0270"))
    end

    # It used to fall back to the first price in the list, which put a Helsinki figure beside a
    # machine made in Nuremberg — beside `max_workers`, which is the only ceiling on the bill.
    # Unknown is the honest answer; another location's number is a wrong one.
    test "a price this location does not have is no price rather than another's" do
      configure(location: "hel1")

      answering_each(%{
        "/server_types" => @types,
        "/datacenters" => selling("hel1", [1, 2])
      })

      assert {:ok, shapes} = Hetzner.shapes(%{"token" => "t"})
      assert Enum.map(shapes, & &1.size) == ["cx23", "cpx32"]
      assert Enum.all?(shapes, &(&1.price_hourly == nil))
    end

    # A type Hetzner lists with no prices at all, and a row missing the fields this reads.
    # Neither should take the catalogue down: a panel that fails to render because one row is
    # odd tells the operator nothing about the other twenty.
    test "a malformed type is still a shape rather than a crash" do
      configure(token: "t", location: "fsn1")

      answering_each(%{
        "/server_types" => %{
          "server_types" => [
            %{
              "id" => 7,
              "name" => "priceless",
              "cores" => 2,
              "memory" => 4.0,
              "deprecation" => nil
            },
            %{"id" => 8, "name" => "bare", "deprecation" => nil, "prices" => []}
          ]
        },
        "/datacenters" => selling("fsn1", [7, 8])
      })

      assert {:ok, [bare, priceless]} = Hetzner.shapes(%{"token" => "t"})

      assert bare.size == "bare"
      assert bare.memory == 0
      assert bare.cores == 0
      assert bare.price_hourly == nil

      assert priceless.size == "priceless"
      assert priceless.memory == 4 * 1024 * 1024 * 1024
      assert priceless.price_hourly == nil
    end
  end

  describe "what the account is holding" do
    # **The assertion the leak panel rests on.** Hetzner pages at 25 by default, so a driver
    # that took the first page for the whole answer would report no orphans while billing for
    # the ones on page two. Three pages here, and all three have to come back.
    test "every page is followed, not just the first" do
      configure(token: "t")
      test = self()

      configure(
        request: fn _method, path, _token, _body ->
          send(test, {:asked, path})

          case path do
            "/servers?" <> _rest = p ->
              page =
                if String.contains?(p, "page=2"),
                  do: 2,
                  else: if(String.contains?(p, "page=3"), do: 3, else: 1)

              {:ok, 200, page_of(page)}
          end
        end
      )

      assert {:ok, instances} = Hetzner.list(%{"token" => "t"})
      assert Enum.map(instances, & &1.provider_id) == ["1", "2", "3"]

      # And it asked for the label, which is what makes these forge's rather than the
      # operator's own servers.
      assert_receive {:asked, first}
      assert first =~ "label_selector=forge%3Dworker"
    end

    defp page_of(3), do: %{"servers" => [server(3)], "meta" => pagination(nil)}
    defp page_of(n), do: %{"servers" => [server(n)], "meta" => pagination(n + 1)}
    defp pagination(next), do: %{"pagination" => %{"next_page" => next}}

    defp server(n) do
      %{"id" => n, "name" => "forge-w#{n}", "status" => "running", "created" => "2026-09-20"}
    end

    test "a server becomes the thin row reconciliation needs" do
      configure(token: "t")

      answering(200, %{
        "servers" => [server(7)],
        "meta" => pagination(nil)
      })

      assert {:ok, [instance]} = Hetzner.list(nil)

      assert instance == %{
               provider_id: "7",
               name: "forge-w7",
               status: "running",
               created_at: "2026-09-20"
             }
    end

    test "an error is reported rather than read as an empty account" do
      configure(token: "t")
      answering(401, %{"error" => %{"message" => "unable to authenticate"}})

      assert {:error, {:hetzner, 401, "unable to authenticate"}} = Hetzner.list(nil)
    end
  end

  describe "the images it can make a machine from" do
    test "snapshots are listed, by the description Hetzner calls their name" do
      configure(token: "t")

      answering(200, %{
        "images" => [
          %{"id" => 42, "description" => "forge-worker", "status" => "available"},
          %{"id" => 7, "description" => "archived", "status" => "creating"}
        ],
        "meta" => %{"pagination" => %{"next_page" => nil}}
      })

      assert {:ok, images} = Hetzner.images(%{"token" => "t"})
      assert Enum.map(images, & &1.id) == ["7", "42"]
      assert Enum.map(images, & &1.name) == ["archived", "forge-worker"]

      # Snapshots only: a system image is not something forge ever boots.
      assert_receive {:hetzner, :get, path, _token, nil}
      assert path =~ "type=snapshot"
    end

    test "an account with no snapshot yet is empty rather than an error" do
      configure(token: "t")
      answering(200, %{"images" => [], "meta" => %{"pagination" => %{"next_page" => nil}}})

      assert {:ok, []} = Hetzner.images(nil)
    end
  end

  test "it declares the one field its credential is made of" do
    assert Hetzner.credential_fields() == [%{key: "token", label: "API token"}]
  end
end
