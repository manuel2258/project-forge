defmodule Forge.Provider.Hetzner do
  @moduledoc """
  Machines from Hetzner Cloud. The second driver, and the test of whether the boundary held —
  `docs/design/worker-tier.md` § The provider driver says so, and nothing above
  `Forge.Provider.*` learned a Hetzner name to make this work.

  **The image is the one thing here that is not an API call.** Hetzner Cloud has no image
  upload: a custom image is made by booting a rescue server, writing the disk, snapshotting it
  and throwing the server away (`worker-tier.md` § Updating a worker). So this driver is
  *given* a snapshot id rather than creating one, by the template — and a template that names
  none cannot make a machine, which it says plainly rather than failing at the API. There is no
  node-wide image to fall back to: the one `Provider.config(:image)` holds is the local
  driver's qcow2 path (`docs/design/provisioning.md` § Where a machine comes from).

  **How a machine learns what it is.** The same `KEY=VALUE` bytes the local driver writes to a
  labelled disk go here as the server's `user_data`. `worker-tier.md` § How a machine learns
  what it is already chose Hetzner's metadata endpoint as the second source, and the image
  reads `http://169.254.169.254/hetzner/v1/userdata` — which returns exactly what was passed
  here. Nothing had to be formatted or parsed for this to work, which was the point of that
  decision.

  **The vendor's memory figure is gross and a machine offers less.** `server_types` reports the
  RAM Hetzner sells; a booted machine offers that less its own reserve for the system and the
  Nix daemon (`ForgeWorker.Config`). A template built straight from a shape therefore promises
  more than its machines deliver, and the gate believes the template — so the first machine
  from a new template shows a disagreement on the workers page, and the number to correct is
  the template's. That is the loop `docs/design/provisioning.md` § What a worker offers
  describes, and it is one correction rather than a running cost.

  **Run only as far as the machine.** Every request here is shaped against Hetzner's published
  API and exercised through a seam, and the real API has been spoken to: machines were created
  and destroyed (the `fsn1` finding below is from one). None has yet connected to a platform and
  run a job. `worker-tier.md` § What the operator's machine
  settled is the standing warning about exactly this: in every case the tests against the fakes
  passed and the real thing did not.
  """

  @behaviour Forge.Provider

  alias Forge.Provider
  alias Forge.Provider.MachineConfig

  require Logger

  @api "https://api.hetzner.cloud/v1"

  # Set at create and asked for at list, which is what makes "is this ours?" answerable without
  # heuristics — and what keeps a leak panel from listing the operator's unrelated servers.
  @label "forge=worker"

  @impl Provider
  def create(opts) do
    with {:ok, token} <- token(opts),
         {:ok, image} <- image_for(opts),
         {:ok, size} <- size(opts) do
      body = %{
        # The worker id, so a machine in Hetzner's console can be matched to a row here without
        # a lookup. Hetzner names must be a valid hostname, and a UUID is one.
        name: "forge-#{opts.worker_id}",
        server_type: size,
        image: image,
        location: location(),
        start_after_create: true,
        user_data: MachineConfig.blob(opts),
        labels: label_map()
      }

      case request(:post, "/servers", token, body) do
        {:ok, 201, %{"server" => server}} ->
          {:ok, %{provider_id: to_string(server["id"]), address: address(server)}}

        {:ok, status, body} ->
          {:error, {:hetzner, status, message(body)}}

        {:error, reason} ->
          {:error, {:hetzner, reason}}
      end
    end
  end

  @impl Provider
  def destroy(provider_id, credential \\ nil) do
    with {:ok, token} <- token(%{credential: credential}) do
      case request(:delete, "/servers/#{provider_id}", token, nil) do
        # **404 is success.** A machine Hetzner has already removed is a machine that is gone,
        # and treating it as an error leaves a row nothing can retire — which holds a
        # `max_workers` slot for ever.
        {:ok, status, _body} when status in [200, 202, 204, 404] ->
          :ok

        {:ok, status, body} ->
          {:error, {:hetzner, status, message(body)}}

        {:error, reason} ->
          {:error, {:hetzner, reason}}
      end
    end
  end

  @impl Provider
  def status(provider_id, credential \\ nil) do
    with {:ok, token} <- token(%{credential: credential}) do
      case request(:get, "/servers/#{provider_id}", token, nil) do
        {:ok, 200, %{"server" => server}} -> {:ok, state(server["status"])}
        {:ok, 404, _body} -> {:ok, :gone}
        {:ok, status, body} -> {:error, {:hetzner, status, message(body)}}
        {:error, reason} -> {:error, {:hetzner, reason}}
      end
    end
  end

  @doc """
  The machine shapes this account can be sold **in the location this node creates in**.

  Two filters, and both exist because offering a size that cannot be made is offering a trap:

  - A **deprecated** type still runs and still lists, but a template built on one stops being
    able to create the day Hetzner withdraws it.
  - A type the configured location cannot currently order is worse, because it fails at create
    with no warning. Hetzner answers `422: unsupported location for server type`, which is how
    this was found: a node left on the default `fsn1` was offered all 25 types while that
    datacenter had *none* orderable, and every template made there failed. Support is not the
    question — `fsn1` supports `cpx11` and cannot sell one — so what is read is each
    datacenter's `server_types.available`, which is the list Hetzner will actually act on.

  **Nothing orderable is an error and not an empty catalogue.** An empty list leaves the form a
  free-text box, which invites typing the name of a machine this location cannot make and
  finding out at create; saying so is the only answer that shortens that loop.
  """
  @impl Provider
  def shapes(credential) do
    with {:ok, token} <- token(%{credential: credential}),
         {:ok, types} <- paginate("/server_types", "server_types", token, []),
         {:ok, orderable} <- orderable(token) do
      types
      |> Enum.reject(&deprecated?/1)
      |> Enum.filter(&MapSet.member?(orderable, &1["id"]))
      |> Enum.map(&shape/1)
      |> Enum.sort_by(& &1.memory)
      |> offered()
    end
  end

  # The ids the configured location will sell today. A location is more than one datacenter in
  # principle, so what is offered is the union of theirs.
  defp orderable(token) do
    with {:ok, datacenters} <- paginate("/datacenters", "datacenters", token, []) do
      location = location()

      {:ok,
       datacenters
       |> Enum.filter(&(get_in(&1, ["location", "name"]) == location))
       |> Enum.flat_map(&(get_in(&1, ["server_types", "available"]) || []))
       |> MapSet.new()}
    end
  end

  defp offered([]), do: {:error, {:hetzner, "no server type is orderable in #{location()}"}}
  defp offered(shapes), do: {:ok, shapes}

  @impl Provider
  def list(credential) do
    with {:ok, token} <- token(%{credential: credential}),
         {:ok, servers} <- paginate("/servers", "servers", token, label_selector: @label) do
      {:ok, Enum.map(servers, &instance/1)}
    end
  end

  @impl Provider
  def images(credential) do
    with {:ok, token} <- token(%{credential: credential}),
         {:ok, images} <- paginate("/images", "images", token, type: "snapshot") do
      {:ok, images |> Enum.map(&image/1) |> Enum.sort_by(& &1.name)}
    end
  end

  @impl Provider
  def credential_fields, do: [%{key: "token", label: "API token"}]

  # Both refused at create below when blank, so a template without them could only ever fail.
  # Declaring them is what lets the template form refuse one instead of saving it.
  @impl Provider
  def required_template_fields, do: [:size, :image]

  # **Followed to the end, and that is not a detail.** Hetzner pages at 25 by default, so a
  # first page taken for the whole answer reports *no orphans* while billing for the ones on
  # page two — a leak panel that lies is worse than no leak panel. `per_page` is asked at the
  # maximum and `meta.pagination.next_page` is nil when there is no more.
  defp paginate(path, key, token, params, page \\ 1, acc \\ []) do
    query = URI.encode_query(Keyword.merge(params, page: page, per_page: 50))

    case request(:get, "#{path}?#{query}", token, nil) do
      {:ok, 200, body} ->
        acc = acc ++ (body[key] || [])

        case get_in(body, ["meta", "pagination", "next_page"]) do
          nil -> {:ok, acc}
          next -> paginate(path, key, token, params, next, acc)
        end

      {:ok, status, body} ->
        {:error, {:hetzner, status, message(body)}}

      {:error, reason} ->
        {:error, {:hetzner, reason}}
    end
  end

  # One source for the label, so the thing set at create and the thing asked for at list cannot
  # drift apart — which would make every machine forge owns look like somebody else's.
  defp label_map do
    [key, value] = String.split(@label, "=", parts: 2)
    %{key => value}
  end

  defp instance(server) do
    %{
      provider_id: to_string(server["id"]),
      name: server["name"],
      status: server["status"],
      created_at: server["created"]
    }
  end

  defp image(image) do
    labels = image["labels"] || %{}

    %{
      id: to_string(image["id"]),
      # Hetzner's own label for a snapshot is `description`; `name` is null for one.
      name: image["description"] || image["name"],
      status: image["status"],
      created: image["created"],
      build: build_label(labels["forge-worker-build"]),
      protocol: protocol_label(labels["forge-worker-protocol"])
    }
  end

  # What `bin/hetzner-image` labels a snapshot with, from the flake that built it
  # (`docs/design/provisioning.md` § A snapshot that speaks the wrong protocol). **A label that
  # is not what the script writes is no label**: nil is *unlabelled*, which the platform treats
  # as unknown and learns about from the join — whereas a misread number would be believed.
  defp build_label(value) when is_binary(value) do
    if value =~ ~r/\A[a-z0-9]{12}\z/, do: value
  end

  defp build_label(_value), do: nil

  defp protocol_label(value) when is_binary(value) do
    case Integer.parse(value) do
      {protocol, ""} -> if ForgeCore.WorkerProtocol.recordable?(protocol), do: protocol
      _other -> nil
    end
  end

  defp protocol_label(_value), do: nil

  @doc """
  What Hetzner's server status means to the platform.

  Everything before a machine is up is `:pending`, because the platform's only use for this is
  *is it worth waiting for*. `deleting` maps to `:gone` rather than `:running`: a machine on its
  way out will not take work, and calling it running would keep a row alive through its own
  destruction.
  """
  @spec state(String.t() | nil) :: :pending | :running | :gone
  def state("running"), do: :running
  def state(status) when status in ~w(initializing starting rebuilding migrating), do: :pending
  def state(_gone), do: :gone

  # Hetzner reports memory in GB as a float and cores as an integer. The figure is what Hetzner
  # sells, not what a booted machine offers — see the note at the head of this module.
  defp shape(type) do
    %{
      size: type["name"],
      memory: round((type["memory"] || 0) * 1024 * 1024 * 1024),
      cores: type["cores"] || 0,
      price_hourly: hourly(type),
      currency: "EUR"
    }
  end

  # Prices are per location and the platform creates in one, so the price shown is that one's.
  # Net rather than gross: the gross figure depends on a VAT rate this platform does not know.
  #
  # **No price rather than another location's.** It used to fall back to the first price in the
  # list, which put a Helsinki figure beside a machine made in Nuremberg — and `max_workers`
  # sits next to that figure precisely because it is what the bill is read from. Since `shapes/1`
  # now offers only what this location sells, the find succeeds for everything it returns; the
  # nil is for a row Hetzner prices oddly, and an empty price reads as unknown rather than wrong.
  defp hourly(type) do
    with prices when is_list(prices) <- type["prices"],
         %{"price_hourly" => %{"net" => net}} <-
           Enum.find(prices, &(&1["location"] == location())),
         {decimal, _rest} <- Decimal.parse(net) do
      decimal
    else
      _other -> nil
    end
  end

  # Where this node makes machines. One reader, because `create/1`, the catalogue and the price
  # must all mean the same place — a catalogue filtered for one location and a create in another
  # is the trap this filter exists to close, rebuilt.
  # The fallback is config.exs's own `nbg1`, for the reason given there: `fsn1`, the old one,
  # sold no x86 type at all. **An equivalent mutant under any configured node**, the test one
  # included — config.exs always names a location — so no test pins it; it is here so that
  # removing that config line does not quietly bring `fsn1` back.
  defp location, do: Provider.config(:location, "nbg1")

  # A deprecated type can still be seen and still be running, but a template built on one stops
  # being able to create the day Hetzner withdraws it. Offering it in a form is offering a trap.
  defp deprecated?(type), do: type["deprecation"] != nil

  defp address(server) do
    get_in(server, ["public_net", "ipv4", "ip"]) || get_in(server, ["public_net", "ipv6", "ip"])
  end

  # The credential is the template's, passed in `opts`; the node-wide token is the fallback for
  # a node that has not moved to per-user credentials yet. A driver with neither says so here
  # rather than sending an unauthenticated request and reporting Hetzner's 401.
  #
  # **Unlike the image's, this fallback is left**, and not because it is right: `:token` is read
  # by no other driver, so it cannot hand Hetzner another driver's value, and nothing in
  # `runtime.exs` sets it. Removing it is its own decision about nodes that set it by hand.
  defp token(opts) do
    case Map.get(opts, :credential) do
      %{"token" => token} when is_binary(token) and token != "" -> {:ok, token}
      _none -> setting(:token, "no Hetzner credential")
    end
  end

  # The template's, and nothing else. It used to fall back to `Provider.config(:image)`, which
  # is not a Hetzner setting: it is the local driver's disk image, a path on this host filled
  # from `FORGE_WORKER_IMAGE`, and a Hetzner template naming no image sent that path to Hetzner
  # as a snapshot id. `Template.changeset/2` now refuses such a template (see
  # `required_template_fields/0`); this is what a template saved before that rule gets.
  defp image_for(opts) do
    case Map.get(opts, :image) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _none -> {:error, {:hetzner, "the template names no image"}}
    end
  end

  defp setting(key, message) do
    case Provider.config(key, nil) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:hetzner, message}}
    end
  end

  # A template with no size is a template that never chose a machine, and Hetzner has no
  # default worth guessing: the smallest type is a machine that cannot hold a build, and the
  # largest is a bill nobody asked for.
  defp size(opts) do
    case Map.get(opts, :size) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:hetzner, "the template names no server type"}}
    end
  end

  defp message(%{"error" => %{"message" => message}}), do: message
  defp message(body), do: inspect(body)

  # The seam. Tests drive a function rather than a network, and the default is the only place
  # that knows what HTTP is.
  #
  # **Everything inside `http/4` is therefore an equivalent mutant under test**, the retry
  # policy included, and none of it should have a test written for it: a test that reached it
  # would be a test that needs a network, and one that faked the network would be asserting
  # against its own fake. That is the boundary this seam exists to draw, and it is why the
  # module's own docs say that what has run against Hetzner was run by hand, not by the suite.
  defp request(method, path, token, body) do
    Provider.config(:request, &__MODULE__.http/4).(method, path, token, body)
  end

  @doc false
  @spec http(atom(), String.t(), String.t(), map() | nil) ::
          {:ok, non_neg_integer(), term()} | {:error, term()}
  def http(method, path, token, body) do
    options =
      [
        method: method,
        url: @api <> path,
        auth: {:bearer, token},
        receive_timeout: Provider.config(:timeout_ms, 30_000),
        # Retrying a create is how two machines get made for one row, so the safe methods
        # retry and the others do not.
        retry: if(method in [:get], do: :safe_transient, else: false)
      ] ++ if(body, do: [json: body], else: [])

    case Req.request(options) do
      {:ok, response} -> {:ok, response.status, response.body}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end
end
