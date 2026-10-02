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
    image: "snapshot-42",
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
      configure(location: "nbg1", token: nil)
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

    # The template's image, even on a node that configures one: `Provider.config(:image)` is the
    # local driver's disk image and was never Hetzner's to read.
    test "a template that names an image is the one booted, not the node's" do
      configure(image: "the-nodes-image", token: "t")
      answering(201, %{"server" => %{"id" => 5}})

      {:ok, _machine} = Hetzner.create(Map.put(@opts, :image, "the-templates-image"))

      assert_receive {:hetzner, :post, _path, _token, body}
      assert body.image == "the-templates-image"
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
    # **Whatever the node configures.** It fell back to `Provider.config(:image)`, which is the
    # key `LocalVm` reads as the path of its qcow2, filled from `FORGE_WORKER_IMAGE` — so on a
    # node set up for local machines a Hetzner template naming no image sent that path to
    # Hetzner as a snapshot id. A template saved before `Template.changeset/2` required one is
    # exactly this call.
    test "a template that names no image, even on a node that configures one" do
      configure(image: "/nix/store/worker-image/nixos.qcow2", token: "t", request: &never/4)

      for opts <- [Map.delete(@opts, :image), Map.put(@opts, :image, nil), %{@opts | image: ""}] do
        assert {:error, {:hetzner, "the template names no image"}} = Hetzner.create(opts)
      end
    end

    test "no credential at all" do
      configure(token: nil, request: &never/4)

      assert {:error, {:hetzner, "no Hetzner credential"}} =
               Hetzner.create(Map.delete(@opts, :credential))
    end

    # An empty token is not a credential, and the guard is `and` for exactly this: read as `or`
    # it accepts `%{"token" => ""}` and sends an unauthenticated request, which comes back as a
    # 401 about a token rather than as the configured fallback being used.
    test "a credential with an empty token falls back to the configured one" do
      configure(token: "from-config")
      answering(201, %{"server" => %{"id" => 9}})

      {:ok, _machine} = Hetzner.create(Map.put(@opts, :credential, %{"token" => ""}))

      assert_receive {:hetzner, :post, _path, "from-config", _body}
    end

    test "a template that names no server type" do
      configure(token: "t", request: &never/4)

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
    # A type's entry for one location, as `GET /server_types` lists it: sold there unless a test
    # says otherwise. Every field is the one Hetzner documents as always present.
    defp sold(location, overrides \\ %{}) do
      Map.merge(
        %{
          "id" => 1,
          "name" => location,
          "deprecation" => nil,
          "recommended" => true,
          "available" => true
        },
        overrides
      )
    end

    defp price(location, net), do: %{"location" => location, "price_hourly" => %{"net" => net}}

    defp withdrawn do
      %{"announced" => "2024-01-01T00:00:00Z", "unavailable_after" => "2024-04-01T00:00:00Z"}
    end

    # cx11 is withdrawn in fsn1 and still sold in nbg1, which is what a per-location deprecation
    # looks like; none of the three is listed in hel1 with a price.
    defp types do
      [
        %{
          "id" => 1,
          "name" => "cpx32",
          "cores" => 4,
          "memory" => 8.0,
          "deprecation" => nil,
          "prices" => [price("fsn1", "0.0250"), price("nbg1", "0.0270")],
          "locations" => [sold("fsn1"), sold("nbg1"), sold("hel1")]
        },
        %{
          "id" => 2,
          "name" => "cx23",
          "cores" => 2,
          "memory" => 4.0,
          "deprecation" => nil,
          "prices" => [price("fsn1", "0.0090"), price("nbg1", "0.0090")],
          "locations" => [sold("fsn1"), sold("nbg1"), sold("hel1")]
        },
        %{
          "id" => 3,
          "name" => "cx11",
          "cores" => 1,
          "memory" => 2.0,
          "deprecation" => nil,
          "prices" => [price("fsn1", "0.0050"), price("nbg1", "0.0050")],
          "locations" => [sold("fsn1", %{"deprecation" => withdrawn()}), sold("nbg1")]
        }
      ]
    end

    # **Anything but `/server_types` is answered as Hetzner answers `/datacenters` since 1 Oct.
    # 2026**, `410 Gone`: the catalogue used to read it, and one that went back to asking would
    # fail every test here rather than pass on an empty body.
    defp catalogue(location, types \\ types()) do
      configure(location: location)
      test = self()

      configure(
        request: fn method, path, token, request_body ->
          send(test, {:hetzner, method, path, token, request_body})

          case path do
            "/server_types?" <> _query ->
              {:ok, 200, %{"server_types" => types}}

            _removed ->
              {:ok, 410, %{"error" => %{"message" => "API functionality was removed"}}}
          end
        end
      )
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

    # The deprecation is the location's: withdrawn in fsn1 is not withdrawn in nbg1, and reading
    # it from any entry would take a machine off a location that still sells it.
    test "a type withdrawn elsewhere is still offered here" do
      catalogue("nbg1")

      assert {:ok, shapes} = Hetzner.shapes(%{"token" => "t"})
      assert Enum.map(shapes, & &1.size) == ["cx11", "cx23", "cpx32"]
    end

    # **The trap this was found as.** A node left on the driver's `fsn1` default was offered all
    # twenty-five server types while that location had none orderable, so every template made
    # there failed at create with `422: unsupported location for server type`. Support is not
    # the question — `fsn1` supports `cpx11` and will not sell one — so what decides is the
    # entry's `available`, not its presence.
    test "a type this location cannot order is not offered" do
      catalogue("fsn1", [
        %{
          "name" => "cpx11",
          "memory" => 2.0,
          "locations" => [sold("fsn1", %{"available" => false}), sold("nbg1")]
        },
        %{"name" => "cax11", "memory" => 4.0, "locations" => [sold("fsn1")]}
      ])

      assert {:ok, shapes} = Hetzner.shapes(%{"token" => "t"})
      assert Enum.map(shapes, & &1.size) == ["cax11"]
    end

    # Another location's availability is not this one's, and reading the wrong entry would
    # rebuild the trap with an extra step.
    test "availability somewhere else is not availability here" do
      catalogue("nbg1", [%{"name" => "cx23", "locations" => [sold("fsn1")]}])

      assert {:error, {:hetzner, message}} = Hetzner.shapes(%{"token" => "t"})
      assert message =~ "nbg1"
    end

    # Saying so rather than answering with nothing: an empty catalogue leaves the form a
    # free-text box, which invites typing a machine this location cannot make and finding out
    # at create.
    test "a location with nothing orderable is an error and not an empty list" do
      catalogue("fsn1", [
        %{"name" => "cx23", "locations" => [sold("fsn1", %{"available" => false})]}
      ])

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
      catalogue("hel1")

      assert {:ok, shapes} = Hetzner.shapes(%{"token" => "t"})
      assert Enum.map(shapes, & &1.size) == ["cx23", "cpx32"]
      assert Enum.all?(shapes, &(&1.price_hourly == nil))
    end

    # A type Hetzner lists with no prices at all, and a row missing the fields this reads.
    # Neither should take the catalogue down: a panel that fails to render because one row is
    # odd tells the operator nothing about the other twenty. A location entry without
    # `available` is the one omission that does count: nothing says the type is sold there.
    test "a malformed type is still a shape rather than a crash" do
      configure(token: "t")

      catalogue("fsn1", [
        %{
          "id" => 7,
          "name" => "priceless",
          "cores" => 2,
          "memory" => 4.0,
          "deprecation" => nil,
          "locations" => [sold("fsn1")]
        },
        %{"id" => 8, "name" => "bare", "prices" => [], "locations" => [sold("fsn1")]},
        %{"name" => "unvouched", "locations" => [Map.delete(sold("fsn1"), "available")]},
        %{"name" => "nowhere"}
      ])

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

    # What `bin/hetzner-image` sets from the flake that built the snapshot. A label that is not
    # what the script writes is read as no label — unknown, which the join settles — and never
    # as a number the platform would then believe.
    test "a snapshot's labels say which build it carries and which protocol that speaks" do
      configure(token: "t")

      label = fn build, protocol ->
        %{"forge-worker-build" => build, "forge-worker-protocol" => protocol}
      end

      answering(200, %{
        "images" => [
          %{"id" => 1, "description" => "a", "labels" => label.("8rh57whmgk6m", "1")},
          %{"id" => 2, "description" => "b", "labels" => %{}},
          %{"id" => 3, "description" => "c"},
          %{"id" => 4, "description" => "d", "labels" => label.("8RH57WHMGK6M", "one")},
          %{"id" => 5, "description" => "e", "labels" => label.("8rh57whmgk6m1", "1.0")},
          %{"id" => 6, "description" => "f", "labels" => label.("short", "-1")},
          # Past what the column holds: recorded, it would crash the save of any template naming it.
          %{"id" => 8, "description" => "h", "labels" => label.("8rh57whmgk6m", "3000000000")}
        ],
        "meta" => %{"pagination" => %{"next_page" => nil}}
      })

      assert {:ok, images} = Hetzner.images(%{"token" => "t"})

      assert Enum.map(images, &{&1.id, &1.build, &1.protocol}) == [
               {"1", "8rh57whmgk6m", 1},
               {"2", nil, nil},
               {"3", nil, nil},
               {"4", nil, nil},
               {"5", nil, nil},
               {"6", nil, nil},
               {"8", "8rh57whmgk6m", nil}
             ]
    end

    test "an account with no snapshot yet is empty rather than an error" do
      configure(token: "t")
      answering(200, %{"images" => [], "meta" => %{"pagination" => %{"next_page" => nil}}})

      assert {:ok, []} = Hetzner.images(nil)
    end
  end

  # A row whose create never answered (`docs/design/provisioning.md` § Whose account) is destroyed
  # by asking for the server made for it: by the name create gives it, **under forge's label** —
  # an operator's own server that shares the name is not forge's to destroy.
  describe "finding the machine made for a worker" do
    test "it asks by the create's name and forge's label, with the credential it is given" do
      answering(200, %{"servers" => [%{"id" => 7, "name" => "forge-w-1"}]})

      assert Hetzner.find("w-1", %{"token" => "hcloud-abc"}) == {:ok, "7"}

      assert_receive {:hetzner, :get, path, "hcloud-abc", nil}
      assert %URI{path: "/servers", query: query} = URI.parse(path)

      assert URI.decode_query(query) == %{
               "name" => "forge-w-1",
               "label_selector" => "forge=worker"
             }
    end

    test "no such server is nothing found, not an error" do
      answering(200, %{"servers" => []})
      assert Hetzner.find("w-1", %{"token" => "t"}) == {:ok, nil}
    end

    # Not "nothing found": a row destroyed on a provider that would not answer would be the leak
    # this exists to close.
    test "a refusal is an error" do
      answering(401, %{"error" => %{"message" => "unable to authenticate"}})

      assert {:error, {:hetzner, 401, "unable to authenticate"}} =
               Hetzner.find("w-1", %{"token" => "t"})
    end

    test "an API that cannot be reached is an error too" do
      configure(request: fn _m, _p, _t, _b -> {:error, "connection refused"} end)

      assert {:error, {:hetzner, "connection refused"}} = Hetzner.find("w-1", %{"token" => "t"})
    end

    test "the name it asks for is the one create gives the server" do
      answering(201, %{"server" => %{"id" => 5}})
      configure(location: "nbg1", token: nil)
      {:ok, _machine} = Hetzner.create(@opts)
      assert_receive {:hetzner, :post, "/servers", _token, %{name: created}}

      answering(200, %{"servers" => []})
      Hetzner.find(@opts.worker_id, %{"token" => "t"})
      assert_receive {:hetzner, :get, path, _token, nil}
      assert URI.decode_query(URI.parse(path).query)["name"] == created
    end
  end

  test "it declares the one field its credential is made of" do
    assert Hetzner.credential_fields() == [%{key: "token", label: "API token"}]
  end

  # Both are refused at create when blank, so a template without them could only fail; saying
  # so here is what lets `Template.changeset/2` refuse one where it is typed.
  test "it declares the template fields it cannot make a machine without" do
    assert Hetzner.required_template_fields() == [:size, :image]
  end
end
