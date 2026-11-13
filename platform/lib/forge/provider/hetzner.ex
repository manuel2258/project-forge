defmodule Forge.Provider.Hetzner do
  @moduledoc """
  Machines from Hetzner Cloud. The second driver, and the test of whether the boundary held —
  `docs/design/worker-tier.md` § The provider driver says so, and nothing above
  `Forge.Provider.*` learned a Hetzner name to make this work.

  **The image is the one thing here that is not a plain API call.** Hetzner Cloud has no image
  upload: a snapshot is made by booting a server whose disk was written and snapshotting it.
  A template is *given* a snapshot id, and a template that names none cannot make a machine, which
  it says plainly rather than failing at the API. When the template names `latest` the platform
  may build the snapshot itself, with a builder server driven by API calls alone (§ building an
  image below, `docs/design/provisioning.md` § Putting the release's image into an account);
  `bin/hetzner-image` remains the by-hand tool. There is no node-wide image to fall back to: the
  one `Provider.config(:image)` holds is the local driver's qcow2 path
  (`docs/design/provisioning.md` § Where a machine comes from).

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
        name: name(opts.worker_id),
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

  Two filters, both read from the type's own entry for that location in its `locations` list,
  and both exist because offering a size that cannot be made is offering a trap:

  - A **deprecated** type still runs and still lists, but a template built on one stops being
    able to create the day Hetzner withdraws it. The deprecation is per location: the type-wide
    `deprecation` is itself deprecated in its favour, and a type can be withdrawn in one
    location while still sold in another.
  - A type the configured location cannot currently order is worse, because it fails at create
    with no warning. Hetzner answers `422: unsupported location for server type`, which is how
    this was found: a node left on the default `fsn1` was offered all 25 types while that
    location had *none* orderable, and every template made there failed. Support is not the
    question — `fsn1` supports `cpx11` and cannot sell one — so what decides is the entry's
    `available`, not its presence.

  **Not the datacenters.** This used to read each datacenter's `server_types.available`, which
  Hetzner deprecated for the per-location fields and then removed with `GET /datacenters`
  itself: since 1 Oct. 2026 it answers `410 Gone`, and every catalogue failed with it.

  **Nothing orderable is an error and not an empty catalogue.** An empty list leaves the form a
  free-text box, which invites typing the name of a machine this location cannot make and
  finding out at create; saying so is the only answer that shortens that loop.
  """
  @impl Provider
  def shapes(credential) do
    with {:ok, token} <- token(%{credential: credential}),
         {:ok, types} <- paginate("/server_types", "server_types", token, []) do
      types
      |> Enum.filter(&orderable?(&1, location()))
      |> Enum.map(&shape/1)
      |> Enum.sort_by(& &1.memory)
      |> offered()
    end
  end

  # Listed for the location, not deprecated there, and available there today. **All three, and
  # `available` must be `true`**: a type Hetzner lists here is only *supported* here, and an
  # entry missing the field is not one this can vouch for.
  defp orderable?(type, location) do
    Enum.any?(
      type["locations"] || [],
      &(&1["name"] == location and &1["deprecation"] == nil and &1["available"] == true)
    )
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

  # Asked by name and label together: the name is the worker id, the label is what makes the
  # server forge's at all, so an operator's own server that happens to share a name is not one.
  @impl Provider
  def find(worker_id, credential) do
    with {:ok, token} <- token(%{credential: credential}) do
      query = URI.encode_query(name: name(worker_id), label_selector: @label)

      case request(:get, "/servers?" <> query, token, nil) do
        {:ok, 200, %{"servers" => [server | _]}} -> {:ok, to_string(server["id"])}
        {:ok, 200, %{"servers" => []}} -> {:ok, nil}
        {:ok, status, body} -> {:error, {:hetzner, status, message(body)}}
        {:error, reason} -> {:error, {:hetzner, reason}}
      end
    end
  end

  # The worker id, so a machine in Hetzner's console can be matched to a row here without a
  # lookup — and so `find/2` can ask for it. Hetzner names must be a valid hostname, and a UUID
  # is one.
  defp name(worker_id), do: "forge-#{worker_id}"

  @impl Provider
  def images(credential) do
    with {:ok, token} <- token(%{credential: credential}),
         {:ok, images} <- paginate("/images", "images", token, type: "snapshot") do
      {:ok, images |> Enum.map(&image/1) |> Enum.sort_by(& &1.name)}
    end
  end

  # -- building an image ----------------------------------------------------------------------
  #
  # `docs/design/provisioning.md` § Putting the release's image into an account. A server made
  # from a stock image whose first-boot script writes the release's image to its own disk and
  # powers off; the platform snapshots it once it is off and deletes it. **Driven by API calls
  # alone**: nothing connects to it, no ssh key is put on it, and a root password the API returns
  # is dropped unread. It is never a worker — it carries a different label, and `list/1` and
  # `find/2` ask only for `forge=worker`.

  @builder_label "forge=image-builder"
  # Read when this module is compiled, so a release carries the script and not a path to it.
  @builder_script_path Path.join(__DIR__, "../../../priv/hetzner/image-builder.sh")
  @external_resource @builder_script_path
  @builder_script File.read!(@builder_script_path)

  @impl Provider
  def start_build(credential, source) do
    with {:ok, token} <- token(%{credential: credential}),
         {:ok, existing} <- find_builder(source.build_id, token) do
      case existing do
        # Asked again after a restart that lost the id: the builder is found, not made twice.
        id when is_binary(id) -> {:ok, builder_handle(source.build_id, id)}
        nil -> create_builder(source, token)
      end
    end
  end

  defp create_builder(source, token) do
    with {:ok, type} <- builder_type(token) do
      body = %{
        name: builder_name(source.build_id),
        server_type: type,
        image: "debian-12",
        location: location(),
        start_after_create: true,
        user_data: builder_script(source),
        labels: builder_labels(source.build_id)
      }

      case request(:post, "/servers", token, body) do
        {:ok, 201, %{"server" => server}} ->
          {:ok, builder_handle(source.build_id, to_string(server["id"]))}

        {:ok, status, body} ->
          {:error, {:hetzner, status, message(body)}}

        {:error, reason} ->
          {:error, {:hetzner, reason}}
      end
    end
  end

  defp builder_handle(build_id, server_id),
    do: %{"build_id" => build_id, "server_id" => server_id}

  defp builder_name(build_id), do: "forge-builder-#{build_id}"

  defp builder_labels(build_id) do
    %{"forge" => "image-builder", "forge-build-id" => build_id}
  end

  # The script with its four values filled in and **nothing else**. The values are validated by
  # `Forge.WorkerImage` and the build id is a UUID; none is a secret, which is the point.
  defp builder_script(source) do
    @builder_script
    |> String.replace("@REPOSITORY@", source.repository)
    |> String.replace("@DIGEST@", source.digest)
    |> String.replace("@RAW_SHA256@", source.raw_sha256)
    |> String.replace("@RAW_SIZE@", to_string(source.raw_size))
  end

  # The cheapest x86 type this location can order with at least 4 GB: the image is downloaded into
  # memory. No setting — the platform picks.
  defp builder_type(token) do
    with {:ok, types} <- paginate("/server_types", "server_types", token, []) do
      types
      |> Enum.filter(
        &(orderable?(&1, location()) and &1["architecture"] == "x86" and
            (&1["memory"] || 0) >= 4)
      )
      |> Enum.sort_by(&{hourly(&1) || Decimal.new(1_000_000), &1["memory"]}, &builder_order/2)
      |> case do
        [type | _] -> {:ok, type["name"]}
        [] -> {:error, {:hetzner, "no x86 server type with 4 GB is orderable in #{location()}"}}
      end
    end
  end

  defp builder_order({a, ma}, {b, mb}) do
    case Decimal.compare(a, b) do
      :lt -> true
      :gt -> false
      :eq -> ma <= mb
    end
  end

  # By name and label together, as `find/2` is, for the same reason.
  defp find_builder(build_id, token) do
    query = URI.encode_query(name: builder_name(build_id), label_selector: @builder_label)

    case request(:get, "/servers?" <> query, token, nil) do
      {:ok, 200, %{"servers" => [server | _]}} -> {:ok, to_string(server["id"])}
      {:ok, 200, %{"servers" => []}} -> {:ok, nil}
      {:ok, status, body} -> {:error, {:hetzner, status, message(body)}}
      {:error, reason} -> {:error, {:hetzner, reason}}
    end
  end

  # An image id means the snapshot has been asked for: the answer is then the image's, and when it
  # is available the mark is moved and the builder deleted, in that order, as `bin/hetzner-image`
  # does (`finish_build/3`). The snapshot is created unmarked; a failed mark or delete answers
  # `{:running, h}` and is tried again on the next poll.
  @impl Provider
  def build_progress(credential, handle) do
    case token(%{credential: credential}) do
      {:ok, token} -> progress(handle, token)
      {:error, reason} -> {:failed, inspect(reason)}
    end
  end

  # **A request that did not get an answer is still running, not failed**: the time limit bounds a
  # provider that stays unreachable, and a build is not thrown away for one dropped connection.
  defp progress(%{"image_id" => image_id} = handle, token) do
    case request(:get, "/images/#{image_id}", token, nil) do
      {:ok, 200, %{"image" => %{"status" => "available"} = image}} ->
        finish_build(handle, image, token)

      {:ok, 200, %{"image" => %{"status" => "creating"}}} ->
        {:running, handle}

      {:ok, 200, %{"image" => image}} ->
        {:failed, "the snapshot is #{image["status"]}"}

      {:ok, 404, _body} ->
        {:failed, "the snapshot is gone"}

      {:ok, status, body} ->
        {:failed, "#{status}: #{message(body)}"}

      {:error, _reason} ->
        {:running, handle}
    end
  end

  defp progress(handle, token) do
    case builder_status(handle, token) do
      # **Off counts only after the builder has been seen running.** A server is also off before
      # its first start and after a failed one, and a person can power it off from the console;
      # none of those has written the image. The sighting is kept in the handle. What it cannot
      # tell is an owner who powers the builder off by hand while it runs.
      {:ok, "running"} ->
        {:running, Map.put(handle, "seen_running", true)}

      {:ok, "off"} when is_map_key(handle, "seen_running") ->
        {:ready, handle}

      {:ok, :gone} ->
        {:failed, "the builder server is gone"}

      {:ok, _not_yet} ->
        {:running, handle}

      {:error, {:hetzner, status, _message} = reason} when is_integer(status) ->
        {:failed, inspect(reason)}

      {:error, _unanswered} ->
        {:running, handle}
    end
  end

  defp builder_status(%{"server_id" => id}, token) when is_binary(id) do
    case request(:get, "/servers/#{id}", token, nil) do
      {:ok, 200, %{"server" => server}} -> {:ok, server["status"]}
      {:ok, 404, _body} -> {:ok, :gone}
      {:ok, status, body} -> {:error, {:hetzner, status, message(body)}}
      {:error, reason} -> {:error, {:hetzner, reason}}
    end
  end

  # The mark moves when the snapshot is available and not before: a snapshot still being made is
  # not one a machine can be created from, and `latest` would have resolved to it for the minutes
  # that takes. Marked first and the others unmarked after, as `bin/hetzner-image` does, so a run
  # cut short leaves two marked rather than none. **Not reported as built until the builder is
  # gone**: a failed mark or delete is tried again on the next poll, both being idempotent, and the
  # time limit bounds the retries.
  defp finish_build(handle, image, token) do
    with :ok <- mark(handle, image, token),
         :ok <- delete_builder(handle, token) do
      {:built, handle["image_id"]}
    else
      _retry -> {:running, handle}
    end
  end

  # **Not over a newer release's mark** (`docs/design/provisioning.md` § Putting the release's
  # image into an account): the version rule was asked when the snapshot was begun, and another
  # node on the same project may have marked a newer snapshot since. Then this one stays unmarked
  # and nothing is moved.
  defp mark(%{"current" => true} = handle, image, token) do
    id = handle["image_id"]
    query = [type: "snapshot", label_selector: "forge-worker-current"]

    case paginate("/images", "images", token, query) do
      {:ok, marked} ->
        others = Enum.reject(marked, &(to_string(&1["id"]) == id))

        if Enum.any?(others, &newer?(&1, handle["version"])),
          do: :ok,
          else:
            put_all(
              [
                {id, Map.put(image["labels"] || %{}, "forge-worker-current", "1")}
                | unmarked(others)
              ],
              token
            )

      {:error, _reason} ->
        :error
    end
  end

  defp mark(_handle, _image, _token), do: :ok

  defp put_all(labelled, token) do
    Enum.reduce_while(labelled, :ok, fn {image_id, labels}, :ok ->
      case request(:put, "/images/#{image_id}", token, %{labels: labels}) do
        {:ok, 200, _body} -> {:cont, :ok}
        _failed -> {:halt, :error}
      end
    end)
  end

  # Hetzner replaces a label set as a whole, so each PUT sends the rest back.
  defp unmarked(images) do
    for %{"id" => id, "labels" => labels} <- images,
        do: {to_string(id), Map.delete(labels, "forge-worker-current")}
  end

  defp newer?(%{"labels" => %{"forge-worker-version" => other}}, version)
       when is_binary(version) do
    case {Version.parse(other), Version.parse(version)} do
      {{:ok, other}, {:ok, ours}} -> Version.compare(other, ours) == :gt
      _unreadable -> false
    end
  end

  defp newer?(_image, _version), do: false

  # **Only a builder seen running and now off is snapshotted**, and one still running never is: a
  # snapshot of a half-written disk is the thing the whole signal exists to prevent.
  @impl Provider
  def snapshot_build(credential, handle, labels) do
    with {:ok, token} <- token(%{credential: credential}),
         :ok <- seen_running(handle),
         {:ok, "off"} <- builder_status(handle, token),
         {:ok, 201, %{"image" => %{"id" => id}}} <-
           request(
             :post,
             "/servers/#{handle["server_id"]}/actions/create_image",
             token,
             snapshot_body(labels)
           ) do
      {:ok,
       handle
       |> Map.put("image_id", to_string(id))
       |> Map.put("current", labels.current)
       |> Map.put("version", labels.version)}
    else
      {:ok, :gone} -> {:error, {:hetzner, "the builder server is gone"}}
      {:ok, status} when is_binary(status) -> {:error, {:hetzner, "the builder is #{status}"}}
      {:ok, status, body} -> {:error, {:hetzner, status, message(body)}}
      {:error, _reason} = error -> error
    end
  end

  defp seen_running(%{"seen_running" => true}), do: :ok
  defp seen_running(_handle), do: {:error, {:hetzner, "the builder was never seen running"}}

  defp snapshot_body(labels) do
    base = %{
      "forge-worker-build" => labels.build,
      "forge-worker-version" => labels.version
    }

    base =
      if labels.protocol,
        do: Map.put(base, "forge-worker-protocol", to_string(labels.protocol)),
        else: base

    %{
      description: "forge-worker-#{labels.version}",
      type: "snapshot",
      labels: base
    }
  end

  @impl Provider
  def discard_build(credential, handle) do
    with {:ok, token} <- token(%{credential: credential}), do: delete_builder(handle, token)
  end

  defp delete_builder(%{"server_id" => id}, token) when is_binary(id) do
    case request(:delete, "/servers/#{id}", token, nil) do
      {:ok, status, _body} when status in [200, 202, 204, 404] -> :ok
      {:ok, status, body} -> {:error, {:hetzner, status, message(body)}}
      {:error, reason} -> {:error, {:hetzner, reason}}
    end
  end

  # No id: a build that never got a handle, discarded by its id alone (`Provider.discard_build/2`).
  # The platform may have stopped between the request that made the builder and the answer that
  # named it, so the builder is found by name, as `start_build` does.
  defp delete_builder(%{"build_id" => build_id}, token) do
    case find_builder(build_id, token) do
      {:ok, nil} -> :ok
      {:ok, id} -> delete_builder(%{"server_id" => id}, token)
      {:error, _reason} = error -> error
    end
  end

  @impl Provider
  def sweep_builders(credential, max_age_ms) do
    with {:ok, token} <- token(%{credential: credential}),
         {:ok, servers} <-
           paginate("/servers", "servers", token, label_selector: @builder_label) do
      now = DateTime.utc_now()

      for server <- servers, past?(server["created"], now, max_age_ms) do
        delete_builder(%{"server_id" => to_string(server["id"])}, token)
      end

      :ok
    end
  end

  # Unparseable is not past: a builder that cannot be dated is not one anybody may delete.
  defp past?(created, now, max_age_ms) when is_binary(created) do
    case DateTime.from_iso8601(created) do
      {:ok, at, _offset} -> DateTime.diff(now, at, :millisecond) > max_age_ms
      _bad -> false
    end
  end

  defp past?(_created, _now, _max_age_ms), do: false

  @impl Provider
  def credential_fields, do: [%{key: "token", label: "API token"}]

  @doc """
  An hour. Hetzner charges every hour a server has started — *"if you create a server just for a
  few minutes, we will still bill you for one whole hour"* — for as long as it exists, running or
  not, up to the type's monthly price (`docs/design/worker-tier.md` § The hour already paid for).

  **Counted from the server's creation, which is inferred and not observed here.** Hetzner does
  not say whether an hour runs from creation or from the clock; two autoscalers built against it
  count from creation, and that note says what it costs if they are wrong and how to find out.
  """
  @impl Provider
  def billed_increment_ms, do: :timer.hours(1)

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
      protocol: protocol_label(labels["forge-worker-protocol"]),
      version: version_label(labels["forge-worker-version"]),
      current: Map.has_key?(labels, "forge-worker-current")
    }
  end

  # **Presence is the whole label**, value and all: `bin/hetzner-image` writes `=1` and nothing
  # reads the 1, so a snapshot marked by hand with `=yes` or with nothing after the `=` is marked.
  # Unlike the build and the protocol there is no value here to misread, and so nothing to refuse.

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

  # **Only a version `Version.parse/1` can read**; anything else is no version, which is never
  # newer than a release's (`Forge.WorkerImage.newer_in?/2`).
  defp version_label(value) when is_binary(value) do
    case Version.parse(value) do
      {:ok, _version} -> value
      :error -> nil
    end
  end

  defp version_label(_value), do: nil

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
