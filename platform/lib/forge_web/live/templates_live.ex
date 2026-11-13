defmodule ForgeWeb.TemplatesLive do
  @moduledoc """
  Worker templates and the provider credentials they spend: what a machine is made from, how
  many of them there may be, and which projects may have them made — the Templates and
  Credentials views of the machines page (`docs/design/ui.md` § Templates and credentials,
  `14a`–`14f`).

  `docs/design/provisioning.md`, and `docs/design/ui.md` §§ Creating things and The affordance
  rule. Two things about this page that are not like the others:

  - **It is the first operator surface where a number is money that keeps accruing.** A
    template's `max_workers` is the only ceiling on machine spend, so a template leads with that
    ceiling in money — the maximum times the price per machine, in the currency the provider's
    catalogue reports — and draws none where the catalogue names no price.
  - **It is per user, not per node.** A credential belongs to whoever entered it and a template
    to whoever made it, so this page shows one person's own and never anybody else's. That is
    `identity.md` § Credentials applied to infrastructure, and it is why this is not behind
    `node_admin`: a node admin has no more claim on a machine's bill than anyone else.

  **The catalogue is read once per credential per mount**, and never per row: the ceilings, the
  credentials' liabilities and the form's sizes all come from one cache (`catalogues`). The view
  is in the URL — `?view=credentials`, `?template=<id>`, `?new=1` — so back and reload land on it.

  The secret's shape comes from the driver (`Forge.Provider.credential_fields/1`), so this page
  asks for one token or a key pair without knowing which provider wants which.

  **The template form asks for nothing until an account is named.** A machine's sizes and images
  are read from the account that pays for them, so a provider that takes a credential shows only
  its name and its credential until one of the operator's is chosen — and the credential select
  offers no *none*, because a template naming no account could only fall back to the node's own
  token (`provisioning.md` § Where a machine comes from).
  """

  use ForgeWeb, :live_view

  import ForgeCore.Workflow.Resources, only: [gib: 1]
  import ForgeWeb.ProjectAssign, only: [project_assign: 1]

  alias Forge.{ImageBuilds, Projects, Provider, Provisioning, WorkerImage, Workers}
  alias Forge.Provisioning.Template
  alias ForgeWeb.{Format, WorkersLive}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Templates",
       view: "templates",
       open: nil,
       editing: nil,
       catalogues: %{},
       listings: %{}
     )
     |> load()
     |> reset_forms()
     |> load_listings()
     |> schedule_refresh()}
  end

  # The account's snapshots, read once on mount (and again when a build ends) so that *Build now*
  # is offered only when it would do something. Asynchronously: it is a request to the provider
  # per credential, and the page must not wait on one.
  defp load_listings(socket) do
    credentials = Enum.filter(socket.assigns.credentials, &Provider.builds?(&1.provider))

    if connected?(socket) and credentials != [] and socket.assigns.release != nil do
      start_async(socket, :listings, fn ->
        Map.new(credentials, &{&1.id, ImageBuilds.listing(&1)})
      end)
    else
      socket
    end
  end

  @impl true
  def handle_async(:listings, {:ok, listings}, socket),
    do: {:noreply, assign(socket, listings: listings)}

  def handle_async(:listings, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh_builds, socket) do
    before = running?(socket.assigns.builds)
    socket = assign(socket, builds: ImageBuilds.recent(socket.assigns.current_scope.user))

    socket =
      if before and not running?(socket.assigns.builds), do: load_listings(socket), else: socket

    {:noreply, socket |> schedule_refresh()}
  end

  # Only while a build runs, and only from a connected page: nothing ticks for a page nobody has
  # open.
  defp schedule_refresh(socket) do
    if connected?(socket) and running?(socket.assigns.builds),
      do: Process.send_after(self(), :refresh_builds, Forge.ImageBuilds.Runner.tick_ms())

    socket
  end

  defp running?(builds),
    do: builds |> Map.values() |> List.flatten() |> Enum.any?(&(&1.status == :running))

  # The view is the URL's: Templates or Credentials, and on Templates one template open
  # (`?template=`) or the new one (`?new=1`). A template is read scoped to the viewer, so another
  # person's id opens nothing, as a missing one does not.
  #
  # **Reading the id unscoped here is an equivalent mutant for every test**: the panel draws the
  # template it finds in `@templates`, which is already the viewer's own, so a foreign id would open
  # an empty panel rather than another person's template. The scoped read is kept so that `open`
  # never holds an id this page did not check, and no test is written that could not fail.
  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] == "credentials", do: "credentials", else: "templates"
    open = opened(view, params, socket.assigns.current_scope.user)
    socket = assign(socket, view: view, page_title: page_title(view))

    socket =
      cond do
        open == :new and socket.assigns.open != :new ->
          socket |> assign(open: :new) |> reset_forms()

        socket.assigns.editing && socket.assigns.editing != open ->
          socket |> assign(open: open) |> reset_forms()

        true ->
          assign(socket, open: open)
      end

    {:noreply, socket}
  end

  defp opened("credentials", _params, _user), do: nil
  defp opened(_view, %{"new" => _}, _user), do: :new

  defp opened(_view, %{"template" => id}, user) do
    case Provisioning.template(user, id) do
      nil -> nil
      template -> template.id
    end
  end

  defp opened(_view, _params, _user), do: nil

  defp page_title("credentials"), do: "Credentials"
  defp page_title(_view), do: "Templates"

  defp load(socket) do
    user = socket.assigns.current_scope.user
    templates = Provisioning.templates(user)

    socket
    |> assign(
      credentials: Provisioning.credentials(user),
      templates: templates,
      counts: Map.new(templates, &{&1.id, Provisioning.live_count(&1)}),
      assignments: Map.new(templates, &{&1.id, Provisioning.for_projects(&1)}),
      projects: Projects.list(user),
      # What has nothing to run on, for the none-yet page's third step: read only when there is
      # no template, which is the only time it is drawn.
      bare: if(templates == [], do: bare_projects(user), else: []),
      providers: Provider.names(),
      current_build: Workers.current_build(),
      release: WorkerImage.release(),
      builds: ImageBuilds.recent(user),
      # **Only the providers that have a credential to give.** A driver whose
      # `credential_fields/0` is empty reaches its machines without an account — the local one
      # does — so offering it here is offering a form with nothing in it, which
      # `Credential.changeset/2` then refuses for having an empty secret. A local *template*
      # carries a null credential and that is the design (`provisioning.md` § Where a machine
      # comes from); a local *credential* is not a thing.
      credentialled: Enum.filter(Provider.names(), &(Provider.credential_fields(&1) != []))
    )
    |> ceilings()
  end

  defp bare_projects(user) do
    for %{project: project, templates: 0, machines: 0} <- Projects.summaries(user), do: project
  end

  # Every template's ceiling, from the catalogue of the account it names. A catalogue already read
  # on this mount is not read again: a template added later on the same account costs nothing.
  defp ceilings(socket) do
    socket =
      socket.assigns.templates
      |> Enum.map(&{&1.provider, &1.provider_credential_id})
      |> Enum.reduce(socket, fn key, socket -> socket |> shapes_for(key) |> elem(1) end)

    assign(socket,
      ceilings:
        Map.new(socket.assigns.templates, &{&1.id, ceiling(&1, socket.assigns.catalogues)})
    )
  end

  # The shapes one account sells, from the cache or — once — from the driver. A provider that
  # needs a credential is not asked without one: a catalogue is a question about an account.
  defp shapes_for(socket, {provider, credential_id} = key) do
    case socket.assigns.catalogues do
      %{^key => result} ->
        {result, socket}

      cache ->
        secret = secret_of(socket, credential_id)

        result =
          if needs_credential?(provider) and is_nil(secret),
            do: {:error, :no_credential},
            else: Provider.shapes(provider, secret)

        {result, assign(socket, catalogues: Map.put(cache, key, result))}
    end
  end

  defp secret_of(_socket, nil), do: nil

  defp secret_of(socket, credential_id) do
    with %{} = credential <- Enum.find(socket.assigns.credentials, &(&1.id == credential_id)),
         {:ok, secret} <- Provisioning.Credential.secret(credential) do
      secret
    else
      _other -> nil
    end
  end

  @doc """
  What one machine from `template` costs an hour, from `catalogues` — `{price, currency}` — or nil
  when the account's catalogue could not be read, does not sell the template's size, or names
  no price or no currency for it. **Nil and never zero**: an unknown price is not a free one.
  """
  @spec unit_price(Template.t(), map()) :: {Decimal.t(), String.t()} | nil
  def unit_price(%Template{size: size} = template, catalogues) when is_binary(size) do
    with {:ok, shapes} <-
           Map.get(catalogues, {template.provider, template.provider_credential_id}),
         %{price_hourly: %Decimal{} = price, currency: currency} when is_binary(currency) <-
           Enum.find(shapes, &(&1.size == size)) do
      {price, currency}
    else
      _other -> nil
    end
  end

  def unit_price(_template, _catalogues), do: nil

  @doc """
  A template's ceiling (`docs/design/ui.md` § Templates and credentials): its `max_workers` times
  the price of one machine, in the catalogue's currency — or nil when there is no price.
  """
  @spec ceiling(Template.t(), map()) ::
          %{each: Decimal.t(), total: Decimal.t(), currency: String.t()} | nil
  def ceiling(template, catalogues) do
    case unit_price(template, catalogues) do
      nil ->
        nil

      {price, currency} ->
        %{each: price, total: Decimal.mult(price, template.max_workers), currency: currency}
    end
  end

  @symbols %{"EUR" => "€", "USD" => "$", "GBP" => "£"}

  @doc """
  An amount an hour in its currency: `€0.044/h`, `$0.120/h`, `0.300 CHF/h` for a currency with
  no symbol here. Three places, the precision a provider prices machines to by the hour.
  """
  @spec money(Decimal.t(), String.t()) :: String.t()
  def money(amount, currency) do
    figure = amount |> Decimal.round(3) |> Decimal.to_string(:normal)

    case @symbols[currency] do
      nil -> "#{figure} #{currency}/h"
      symbol -> "#{symbol}#{figure}/h"
    end
  end

  @doc """
  What an amount an hour comes to over a month of running, said as an estimate: `≈ €118/mo`.
  A provider bills by the hour, and a person budgets by the month (UX pass, D24); a month is
  taken as 730 hours, a year's over twelve.
  """
  @spec monthly(Decimal.t(), String.t()) :: String.t()
  def monthly(hourly, currency) do
    figure = hourly |> Decimal.mult(730) |> Decimal.round(0) |> Decimal.to_string(:normal)

    case @symbols[currency] do
      nil -> "≈ #{figure} #{currency}/mo"
      symbol -> "≈ #{symbol}#{figure}/mo"
    end
  end

  # Ceilings added up, one sum per currency: two providers billing in two currencies are never
  # summed into one figure. Empty when nothing has a price.
  defp total(ceilings) do
    ceilings
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.currency)
    |> Enum.sort()
    |> Enum.map_join(" + ", fn {currency, list} ->
      list
      |> Enum.map(& &1.total)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      |> money(currency)
    end)
  end

  # What the open form's sizes sell, the shapes and images of the account it names: read when a
  # form is open, and never on a page that shows none. Shapes come out of the same cache as the
  # ceilings, so an account the list already priced is not asked twice.
  #
  # **A provider that takes a credential is not asked anything until it has one.** A catalogue
  # is a question about an account, so with no account named there is nothing to ask and the
  # driver's refusal is not an error worth showing: the page used to mount on Hetzner with no
  # credential chosen and render *no Hetzner credential* twice in red before the operator had
  # done anything. `template_ready` is the same condition seen from the form's side — what
  # there is no point in filling in until an account pays for it.
  defp load_shapes(socket) do
    provider = socket.assigns.template_provider

    credential =
      Enum.find(socket.assigns.credentials, &(&1.id == socket.assigns.template_credential))

    ready = credential != nil or not needs_credential?(provider)
    socket = assign(socket, template_ready: ready)

    if ready and (socket.assigns.open == :new or socket.assigns.editing != nil) do
      {shapes, socket} = shapes_for(socket, {provider, credential && credential.id})

      socket
      |> assign(catalogue(shapes, :shapes))
      |> assign(
        catalogue(
          Provider.images(provider, secret_of(socket, credential && credential.id)),
          :images
        )
      )
    else
      assign(socket, shapes: [], shapes_error: nil, images: [], images_error: nil)
    end
  end

  # A provider whose driver declares no credential fields reaches its machines without an
  # account — the local one does — and a credential for it is a category that does not exist
  # (`docs/design/provisioning.md` § Whose account).
  defp needs_credential?(provider), do: Provider.credential_fields(provider) != []

  # The credential the template form should hold for this provider: the one chosen, when it is
  # that provider's, and otherwise that provider's first.
  #
  # **The chosen one is checked against the provider rather than trusted.** Changing the
  # provider arrives here with the *old* provider's credential still in the params, because the
  # select has not re-rendered yet; carrying it would fetch one account's catalogue under
  # another provider's driver and then be refused by `Template.changeset/2` on submit.
  defp credential_for(socket, provider, chosen) do
    for_provider = Enum.filter(socket.assigns.credentials, &(&1.provider == provider))

    case Enum.find(for_provider, &(&1.id == blank(chosen))) do
      nil -> for_provider |> List.first() |> then(&(&1 && &1.id))
      credential -> credential.id
    end
  end

  # Both catalogues fail the same way and for the same reasons — a bad token, an API that is
  # down — and neither is fatal: the fields stay typeable, which is what they were before a
  # catalogue existed. A page that refused to render because a provider was unreachable would
  # be a page you cannot use to fix the credential.
  defp catalogue({:ok, entries}, key), do: [{key, entries}, {:"#{key}_error", nil}]
  defp catalogue({:error, reason}, key), do: [{key, []}, {:"#{key}_error", inspect(reason)}]

  defp reset_forms(socket) do
    provider = List.first(socket.assigns.providers) || "local"
    # The credential form defaults to a provider that actually takes one, which is not
    # necessarily the one the template form defaults to.
    for_credential = List.first(socket.assigns.credentialled)
    # The first credential this provider has, because the select offers no way to choose none:
    # a machine is billed to an account, and a select showing one while the catalogue was
    # fetched with another would be a form lying about what it is about to spend.
    credential = credential_for(socket, provider, nil)

    socket
    |> assign(
      credential_form: to_form(%{"provider" => for_credential, "name" => ""}, as: :credential)
    )
    |> assign(credential_provider: for_credential)
    |> assign(credential_seq: (socket.assigns[:credential_seq] || 0) + 1)
    |> assign(
      template_form:
        to_form(
          %{
            "provider" => provider,
            "provider_credential_id" => credential || "",
            "name" => "",
            "max_workers" => "1"
          },
          as: :template
        )
    )
    |> assign(
      template_provider: provider,
      template_credential: credential,
      editing: nil,
      error: nil
    )
    |> load_shapes()
  end

  # The form filled from a template, for editing it. The two forms share one catalogue — it is
  # keyed on `template_provider` — so only one of them may be open at a time, which is why
  # `editing` hides the create form rather than sitting beside it.
  defp editing(socket, template) do
    params =
      %{
        "provider" => template.provider,
        "provider_credential_id" => template.provider_credential_id || "",
        "name" => template.name,
        "size" => template.size || "",
        "image" => template.image || "",
        "memory" => ForgeCore.Workflow.Resources.humanize(template.memory),
        "cores" => to_string(template.cores),
        "max_workers" => to_string(template.max_workers),
        "idle_minutes" => minutes(template.idle_ms)
      }
      |> Map.merge(ticked(template.accepts))

    socket
    |> assign(editing: template.id, error: nil)
    |> assign(template_form: to_form(params, as: :template))
    |> assign(template_provider: template.provider)
    |> assign(
      template_credential:
        credential_for(socket, template.provider, template.provider_credential_id)
    )
    |> load_shapes()
  end

  defp minutes(nil), do: ""
  defp minutes(ms), do: to_string(div(ms, 60_000))

  # Nil accepts is *any kind*, which is nothing ticked — the same reading `accepts/1` writes.
  defp ticked(nil), do: %{}
  defp ticked(accepts), do: Map.new(accepts, &{"accepts_#{&1}", "true"})

  @impl true
  # **Only the name and the provider are kept.** A `phx-change` form sends every field on every
  # keystroke, so what arrives here includes whatever has been typed into the secret, and
  # assigning it whole put the token in this LiveView's state and — because `<.input>` renders a
  # password field's value like any other — back into the page. The secret inputs are
  # `phx-update="ignore"`, so the server rendering them empty does not wipe what was typed.
  def handle_event("credential-provider", %{"credential" => params}, socket) do
    {:noreply,
     socket
     |> assign(credential_provider: params["provider"])
     |> assign(credential_form: to_form(Map.take(params, ["name", "provider"]), as: :credential))}
  end

  def handle_event("add-credential", %{"credential" => params}, socket) do
    fields = Provider.credential_fields(params["provider"])
    secret = Map.new(fields, &{&1.key, String.trim(params[&1.key] || "")})

    attrs = %{
      name: String.trim(params["name"] || ""),
      provider: params["provider"],
      secret: secret
    }

    case Provisioning.create_credential(socket.assigns.current_scope.user, attrs) do
      {:ok, _credential} -> {:noreply, socket |> load() |> reset_forms()}
      {:error, changeset} -> {:noreply, assign(socket, error: errors(changeset))}
    end
  end

  # **Both are the caller's own credential, whatever id arrives** (`ImageBuilds.set_auto/3`): the
  # page offers them only on its own rows, but the event is a request anyone can send.
  def handle_event("set-auto", %{"id" => id, "on" => on}, socket) do
    ImageBuilds.set_auto(socket.assigns.current_scope.user, id, on == "true")
    {:noreply, load(socket)}
  end

  def handle_event("build-now", %{"id" => id}, socket) do
    case ImageBuilds.build_now(socket.assigns.current_scope.user, id) do
      {:ok, _build} -> {:noreply, socket |> load() |> assign(error: nil) |> schedule_refresh()}
      {:error, reason} -> {:noreply, socket |> load() |> assign(error: build_refusal(reason))}
    end
  end

  def handle_event("delete-credential", %{"id" => id}, socket) do
    Provisioning.delete_credential(socket.assigns.current_scope.user, id)
    {:noreply, socket |> load() |> refresh_credential() |> assign(error: nil)}
  end

  def handle_event("template-provider", %{"template" => params}, socket) do
    provider = params["provider"]
    credential = credential_for(socket, provider, params["provider_credential_id"])

    params =
      params
      |> fill_from_shape(socket.assigns.shapes, socket.assigns.template_form.params["size"])
      |> Map.put("provider_credential_id", credential || "")

    {:noreply,
     socket
     |> assign(template_provider: provider)
     |> assign(template_credential: credential)
     |> assign(template_form: to_form(params, as: :template))
     |> load_shapes()}
  end

  def handle_event("add-template", %{"template" => params}, socket) do
    attrs = params |> template_attrs() |> labelled(socket.assigns.images)

    with :ok <- enough_memory(attrs),
         {:ok, template} <-
           Provisioning.create_template(socket.assigns.current_scope.user, attrs) do
      {:noreply,
       socket
       |> assign(open: nil)
       |> load()
       |> reset_forms()
       |> push_patch(to: ~p"/templates?template=#{template.id}")}
    else
      {:error, message} when is_binary(message) -> {:noreply, assign(socket, error: message)}
      {:error, changeset} -> {:noreply, assign(socket, error: errors(changeset))}
    end
  end

  # The id is the client's, so the template is read scoped to the caller before anything is
  # filled in from it — `identity.md` § Sequencing records this as the shape these holes keep
  # taking.
  def handle_event("edit-template", %{"id" => id}, socket) do
    case Provisioning.template(socket.assigns.current_scope.user, id) do
      nil -> {:noreply, socket}
      template -> {:noreply, editing(socket, template)}
    end
  end

  def handle_event("cancel-edit", _params, socket), do: {:noreply, reset_forms(socket)}

  # **`Provisioning.update_template/3` is the guard**: it reads the template scoped to the
  # caller and pins the owner, so the id this sends is checked where the write is. `editing` is
  # server state, set only by `edit-template` above after its own scoped read, so from this page
  # the context's check never refuses anything — it is there for the day somebody sets `editing`
  # from params, and it is tested at the context rather than here, where no test could fail.
  def handle_event("save-template", %{"template" => params}, socket) do
    user = socket.assigns.current_scope.user

    attrs = params |> template_attrs() |> labelled(socket.assigns.images)

    with :ok <- enough_memory(attrs),
         {:ok, _template} <- Provisioning.update_template(user, socket.assigns.editing, attrs) do
      {:noreply, socket |> load() |> reset_forms()}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, error: message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, error: errors(changeset))}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  # **Editing does not do this**, and that is the rule rather than an omission: a rename is not
  # a fix, and a template that earns three more tries every time somebody touches it is the
  # loop this counter exists to stop (`provisioning.md` § A template that cannot make a working
  # machine is taken out of service).
  def handle_event("enable-template", %{"id" => id}, socket) do
    case Provisioning.enable(socket.assigns.current_scope.user, id) do
      {:ok, _template} -> {:noreply, socket |> load() |> assign(error: nil)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("delete-template", %{"id" => id}, socket) do
    Provisioning.delete_template(socket.assigns.current_scope.user, id)

    {:noreply,
     socket |> assign(open: nil) |> load() |> reset_forms() |> push_patch(to: ~p"/templates")}
  end

  def handle_event("assign", %{"template" => id, "project" => project_id}, socket) do
    case Provisioning.assign(socket.assigns.current_scope.user, id, project_id) do
      {:ok, _} -> {:noreply, socket |> load() |> assign(error: nil)}
      {:error, :not_a_member} -> {:noreply, assign(socket, error: "you are not in that project")}
      {:error, _reason} -> {:noreply, assign(socket, error: "could not assign it")}
    end
  end

  def handle_event("unassign", %{"template" => id, "project" => project_id}, socket) do
    Provisioning.unassign(socket.assigns.current_scope.user, id, project_id)
    {:noreply, socket |> load() |> assign(error: nil)}
  end

  # The credential the template form holds may have just been the one removed, and a select
  # offering a row that no longer exists would create a template against nothing. Re-resolving
  # is not the same as resetting the form: whatever was typed into it stays.
  defp refresh_credential(socket) do
    credential =
      credential_for(socket, socket.assigns.template_provider, socket.assigns.template_credential)

    params =
      Map.put(socket.assigns.template_form.params, "provider_credential_id", credential || "")

    socket
    |> assign(template_credential: credential)
    |> assign(template_form: to_form(params, as: :template))
    |> load_shapes()
  end

  # Choosing a size fills the two numbers that go with it. Only when the *size* changed, so an
  # operator who then edits the memory by hand keeps their edit — a form that overwrote it on
  # every keystroke would be a form that cannot be corrected.
  #
  # **`was` is what makes that true, and for a while nothing did.** The clause only asked
  # whether the size in the params matched a shape, which every change event carries once a
  # size is chosen, so picking `cpx31` and then touching the image select wrote the shape's
  # memory back over whatever had been typed. `phx-change` fires on the whole form, not on the
  # field that moved: the previous value is the only thing that says the size is what changed.
  defp fill_from_shape(params, shapes, was) do
    size = params["size"]

    case Enum.find(shapes, &(&1.size == size and size not in [nil, ""] and size != was)) do
      nil ->
        params

      shape ->
        # The unit a person would type, not the byte count. The field is labelled `8GiB` and
        # filling it with `8589934592` made the form argue with its own label — and, until
        # `parse_bytes/1` took a bare numeric string, refuse the very value it had written.
        Map.merge(params, %{
          "memory" => ForgeCore.Workflow.Resources.humanize(shape.memory),
          "cores" => to_string(shape.cores)
        })
    end
  end

  # Blank is nil and not zero, throughout: a field left empty means *nothing said*, and reading
  # it as a number would give a template no memory or an idle period of no time at all.
  defp template_attrs(params) do
    %{
      name: String.trim(params["name"] || ""),
      provider: params["provider"],
      provider_credential_id: blank(params["provider_credential_id"]),
      size: blank(params["size"]),
      image: blank(params["image"]),
      memory: bytes(params["memory"]),
      cores: number(params["cores"]),
      max_workers: number(params["max_workers"]),
      idle_ms: minutes_to_ms(params["idle_minutes"]),
      accepts: accepts(params)
    }
  end

  # **What the chosen snapshot carries, from the listing this page already holds** — never from the
  # form, whose params are the client's (`docs/design/provisioning.md` § A snapshot that speaks the
  # wrong protocol). An image the listing does not have — typed by hand for a provider that lists
  # none, or gone since the page loaded — is unlabelled, and `Template.changeset/2` keeps what is
  # already known about an image that did not change.
  # **And for `latest`, what the snapshot now marked carries**, so the page says something
  # sensible the moment the template is saved rather than after its first machine. A seed and not
  # the authority: `Forge.Workers` re-asks the driver at every create, so a stale one shows a
  # wrong build on this page until then and never makes a machine from the wrong snapshot
  # (`docs/design/provisioning.md` § Where a machine comes from).
  defp labelled(attrs, images) do
    image =
      if Template.latest?(attrs),
        do: Provisioning.current_image(images),
        else: Enum.find(images, &(&1.id == attrs.image))

    Map.merge(attrs, %{
      # Only for `latest`. A snapshot id resolves to itself and `Template.changeset/2` is what
      # says so, so this page does not carry a second copy of that rule; nil here is *nothing
      # new*, which a save of an unchanged image keeps rather than forgets.
      resolved_image: if(Template.latest?(attrs), do: image && image.id),
      image_build: image && image[:build],
      image_protocol: image && image[:protocol]
    })
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(value), do: String.trim(value)

  defp number(value) do
    case Integer.parse(to_string(value)) do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp minutes_to_ms(value) do
    case number(value) do
      nil -> nil
      minutes -> minutes * 60_000
    end
  end

  # **A machine smaller than the least one job can run in makes nothing anybody can use**, so it is
  # refused here, by name, before anything is saved (`docs/design/workflow-grammar-v1.md`
  # § Resources). On the page and not the schema: what a template may not be is decided by the
  # job it would hold, and a job below the minimum is refused where its row is made — a template
  # of eight thousand bytes that some other caller made holds no job, which the gate already
  # says. A figure nobody typed is the changeset's to call blank.
  defp enough_memory(%{memory: bytes}) when is_integer(bytes) do
    if ForgeCore.Workflow.Resources.enough_memory?(bytes),
      do: :ok,
      else: {:error, ForgeCore.Workflow.Resources.memory_refused()}
  end

  defp enough_memory(_attrs), do: :ok

  # The same units the grammar accepts, so an operator who writes `8GiB` in a workflow can write
  # it here (`docs/design/workflow-grammar-v1.md` § Resources).
  defp bytes(value) do
    case ForgeCore.Workflow.Resources.parse_bytes(blank(value) || "") do
      {:ok, bytes} -> bytes
      _other -> nil
    end
  end

  # Nothing ticked is nil rather than an empty list: "takes anything", the same reading a worker
  # that reported no kinds gets.
  #
  # **Returning `[]` here is an equivalent mutant and must not have a test written for it.**
  # `Workers.accepts?/2` and `Provisioning.holds?/2` both answer `true` for an empty list as
  # well as for nil, on purpose, so the two are indistinguishable by every path that reads
  # them. Nil is chosen because it is what the column means elsewhere, not because anything
  # behaves differently.
  defp accepts(params) do
    case Enum.filter(Forge.Jobs.Job.kinds(), &(params["accepts_#{&1}"] == "true")) do
      [] -> nil
      kinds -> kinds
    end
  end

  defp errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp shape_label(shape) do
    "#{shape.size} — #{gib(shape.memory)}, #{shape.cores} cores" <> price(shape)
  end

  defp price(%{price_hourly: %Decimal{} = hourly, currency: currency}) when is_binary(currency),
    do: ", " <> money(hourly, currency)

  defp price(_shape), do: ""

  # The empty option of a select, worded for what leaving it empty does. A provider that cannot
  # make a machine without the field gets a prompt, because *the node's default* would be a
  # promise `Template.changeset/2` then refuses to keep.
  defp blank_choice(required, field, otherwise),
    do: {if(field in required, do: "choose one", else: otherwise), ""}

  # A snapshot as the image select offers it: its name, then what it carries, and whether it is
  # the one `latest` resolves to — so choosing the mark and choosing an id are the same informed
  # choice (`docs/design/provisioning.md` § Where a machine comes from).
  defp image_label(image, current_build) do
    "#{image.name || image.id} · #{carries(image[:build], image[:protocol], current_build)}" <>
      if image[:current], do: " · carries latest", else: ""
  end

  # A row's identifiers: the provider, the size and the image it names. A template naming `latest`
  # names no snapshot, so the one it is resolved to goes after it — the row would otherwise say
  # nothing about which build its next machine comes from.
  defp names(%Template{} = template) do
    [template.provider, template.size, template.image, followed(template)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp followed(%Template{resolved_image: resolved} = template) when is_binary(resolved) do
    if Template.latest?(template), do: "now #{resolved}"
  end

  defp followed(_template), do: nil

  # The mark itself, offered beside the snapshots: a template naming it is made from whichever
  # one carries it at the time, so the option says which that is today. *None marked yet* rather
  # than no option at all, because a provider whose account has never been built for is exactly
  # where a person needs to be told what the word would mean.
  defp latest_label(nil), do: "#{Template.latest()} · none marked yet"
  defp latest_label(current), do: "#{Template.latest()} · #{current.name || current.id}"

  # What a snapshot carries, in the words the template row and the image select share: its build
  # against the one this platform ships with, and its protocol — or *unlabelled*, for a snapshot
  # from before the labels existed, which cannot be identified after the fact.
  defp carries(nil, nil, _current_build), do: "unlabelled"

  defp carries(build, protocol, current_build) do
    [build(build, current_build), protocol && "protocol #{protocol}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # A snapshot whose label names no build is *unknown*, and draws nothing rather than a hint. Not
  # the workers page's reading of a machine that joined with none — which is "other build", since
  # a release outside the Nix store cannot be the one this platform ships with.
  defp build(nil, _current_build), do: nil

  defp build(build, current_build) do
    case Format.build_hint(build, current_build) do
      nil -> "build #{build}"
      hint -> "build #{build} #{hint}"
    end
  end

  # A template whose snapshot this platform would refuse makes nothing, and says so here before
  # any job asks — its failures only begin once one does. Once they have, the failures line
  # carries the same sentence as its last error, and it is not said twice.
  defp refusal(template) do
    case Provisioning.image_refusal(template) do
      nil -> nil
      same when same == template.last_error -> nil
      sentence -> sentence
    end
  end

  defp kinds(nil), do: "any kind"
  defp kinds([]), do: "any kind"
  defp kinds(accepts), do: Enum.map_join(accepts, ", ", &to_string/1)

  attr :credential, :map, required: true
  attr :release, :map, default: nil
  attr :listing, :any, default: nil
  attr :builds, :list, default: []

  # What the platform builds into this account and what it has built (`ui.md` § The workers page). Only
  # the owner's page draws it, and the words a provider or a builder wrote are text, never markup,
  # cut short here with the whole in the log.
  defp image_builds(assigns) do
    assigns =
      assign(assigns, :can, build_now(assigns.credential, assigns.listing, assigns.builds))

    ~H"""
    <div class="credential-builds" data-role="image-builds">
      <p :if={@release == nil} class="credential-builds-note">
        This node has no release build to put there.
      </p>

      <div :if={@release != nil} class="credential-builds-body">
        <button
          type="button"
          role="switch"
          aria-checked={to_string(@credential.build_images)}
          phx-click="set-auto"
          phx-value-id={@credential.id}
          phx-value-on={to_string(!@credential.build_images)}
          class="credential-auto"
        >
          <span>Build worker images automatically</span>
          <span class="credential-switch" aria-hidden="true" />
        </button>

        <div class="credential-build-now">
          <.button
            :if={@can == :ok}
            type="button"
            variant="outline"
            size="md"
            phx-click="build-now"
            phx-value-id={@credential.id}
          >
            Build now
          </.button>
          <span class="credential-builds-note">{build_now_note(@can)}</span>
        </div>

        <ol :if={@builds != []} class="credential-build-list" data-role="builds">
          <li :for={build <- @builds} class="credential-build">
            <span class="credential-build-head">
              <span>{Format.ago_phrase(build.started_at)}</span>
              <span class="credential-build-sha">{build.build}</span>
              <span>{started_by(build)}</span>
            </span>
            <span class={["credential-build-standing", standing_tone(build)]} title={build.message}>
              {standing(build)}
            </span>
          </li>
        </ol>

        <p :if={@builds == []} class="credential-builds-note">
          No builds yet. One is built the first time a template naming latest needs a machine
          here, or now with Build now.
        </p>
      </div>
    </div>
    """
  end

  # `:ok` when pressing it would do something; otherwise why not, in the row's words.
  #
  # **`builds` is an argument so that the expression is tracked by it**: LiveView re-evaluates an
  # expression only when an assign it names changed, and one that asked the database by itself
  # went on offering the button after the build it started was already running.
  defp build_now(_credential, nil, _builds), do: :loading
  defp build_now(_credential, {:error, _reason}, _builds), do: :unreadable

  defp build_now(credential, {:ok, images}, builds) do
    if Enum.any?(builds, &(&1.status == :running)),
      do: {:error, :running},
      else: ImageBuilds.buildable(credential, images)
  end

  defp build_now_note(:ok),
    do: "Costs a few minutes of a small machine on this account."

  defp build_now_note(:loading), do: "Reading this account's snapshots…"
  defp build_now_note(:unreadable), do: "This account's snapshots could not be read."
  defp build_now_note({:error, :running}), do: "A build is running."
  defp build_now_note({:error, :present}), do: "The current build is already in this account."

  defp build_now_note({:error, :newer}),
    do: "This account already holds a newer release; nothing older is built into it."

  defp build_now_note({:error, reason}) when reason in [:no_release, :cannot_build],
    do: "Nothing to build here."

  defp started_by(%{template_name: name}) when is_binary(name), do: "by template #{name}"
  defp started_by(_build), do: "by Build now"

  defp standing(%{status: :running, started_at: at}),
    do: "running, started #{Format.ago_phrase(at)}"

  defp standing(%{status: :built}), do: "built"
  defp standing(%{status: :failed, message: message}), do: "failed: #{message}"
  defp standing(%{status: :abandoned, message: message}), do: message

  defp standing_tone(%{status: :failed}), do: "credential-build-standing--danger"
  defp standing_tone(%{status: :abandoned}), do: "credential-build-standing--warning"
  defp standing_tone(_build), do: nil

  defp build_refusal(:not_found), do: "That credential is not yours."

  defp build_refusal(:unpublished),
    do: "This release's worker image is not published, or not public."

  defp build_refusal({:images, _reason}), do: "This account's snapshots could not be read."
  defp build_refusal(_other), do: "A build would do nothing here."

  # What a template is, beside its ceiling: memory, cores and the kinds of job it takes.
  defp what(template),
    do: "#{gib(template.memory)} · #{template.cores} cores · #{kinds(template.accepts)}"

  attr :made, :integer, required: true
  attr :max, :integer, required: true

  # How many of the maximum run now, as slots (`14a`): **amber when full** — the one place on the
  # machines pages that is, because a full template is new work waiting (`docs/design/ui.md`
  # § Machines). At most twelve drawn; the figure beside them says the rest.
  defp slots(assigns) do
    assigns = assign(assigns, full: assigns.made >= assigns.max)

    ~H"""
    <span class={["template-slots", @full && "template-slots--full"]}>
      <span :if={@max > 0} class="template-slot-row" aria-hidden="true">
        <span
          :for={i <- 1..min(@max, 12)}
          class={["template-slot", i <= @made && "template-slot--on"]}
        />
      </span>
      <span class="template-count">{@made} of {@max}</span>
    </span>
    """
  end

  attr :form, :any, required: true
  attr :credentials, :list, required: true
  attr :provider, :string, required: true
  attr :credential, :string, default: nil
  attr :providers, :list, required: true
  attr :shapes, :list, required: true
  attr :images, :list, required: true
  attr :shapes_error, :string, default: nil
  attr :images_error, :string, default: nil
  attr :ready, :boolean, required: true
  attr :required, :list, required: true
  attr :submit, :string, required: true
  attr :current_build, :string, default: nil
  attr :id, :string, required: true
  slot :beside

  # What a template is made of, in the order the provider needs it (`14c`): the account, then
  # the machine, then the limits, then what it takes — for the form that makes one and the form
  # that edits one. One definition rather than two, because a second would be a copy of eleven
  # fields that drifts the first time one of them changes, and these are the fields most likely
  # to change, since every one of them is something a driver taught the platform to ask for.
  defp template_fields(assigns) do
    assigns = assign(assigns, ceiling: form_ceiling(assigns.shapes, assigns.form.params))

    ~H"""
    <.input field={@form[:name]} type="text" label="Name" autocomplete="off" mono />

    <section class="template-step">
      <h3 class="template-step-head">
        <span class={["template-step-mark", @ready && "template-step-mark--done"]}>
          {if @ready, do: "✓", else: "1"}
        </span>
        Account
      </h3>
      <div class="template-step-pair">
        <.input field={@form[:provider]} type="select" label="Provider" options={@providers} />
        <%!-- Only this provider's credentials, and no way to choose none: what a template
              creates is billed to an account, and a template naming no account could only fall
              back to the node's own token, which is the thing per-user credentials replaced. A
              provider that reaches its machines without an account has no select at all
              (`provisioning.md` § Whose account). --%>
        <.input
          :if={@credential}
          field={@form[:provider_credential_id]}
          type="select"
          label="Credential"
          options={for c <- @credentials, c.provider == @provider, do: {c.name, c.id}}
        />
      </div>
      <p :if={@ready} class="template-step-note">
        Sizes and images are read from this account, which pays for every machine.
      </p>
      <p :if={not @ready} class="template-step-note">
        Add a {@provider} credential first. Its machine sizes and images are read from
        the account that pays for them, so there is nothing to fill in until there is one.
      </p>
    </section>

    <section :if={not @ready} class="template-step template-step--locked" aria-disabled="true">
      <h3
        :for={{n, label} <- [{2, "Machine"}, {3, "Limits"}, {4, "Takes"}]}
        class="template-step-head"
      >
        <span class="template-step-mark">{n}</span>
        {label}
      </h3>
    </section>

    <%!-- `contents`, so the rest of the form is one thing to show or hide while its rows stay
          rows of the form itself. --%>
    <div :if={@ready} class="contents">
      <section class="template-step">
        <h3 class="template-step-head">
          <span class="template-step-mark">2</span> Machine
        </h3>
        <.error_note :if={@shapes_error}>
          could not read {@provider}&#39;s machine sizes: {@shapes_error}
        </.error_note>
        <.error_note :if={@images_error}>
          could not read {@provider}&#39;s images: {@images_error}
        </.error_note>
        <%!-- The driver's own catalogue, so an operator picks a machine that exists rather than
              typing a name that does not. Free text when the provider sells no named shapes,
              which is the local one. The blank choice says what blank does: *custom* where the
              driver takes a template with no size, and *choose one* where it refuses one
              (`Forge.Provider.required_template_fields/1`). --%>
        <.input
          :if={Enum.any?(@shapes, & &1.size)}
          field={@form[:size]}
          type="select"
          label="Size"
          options={
            [blank_choice(@required, :size, "custom")] ++
              for s <- @shapes, s.size, do: {shape_label(s), s.size}
          }
        />
        <.input
          :if={not Enum.any?(@shapes, & &1.size)}
          field={@form[:size]}
          type="text"
          label="Size"
          autocomplete="off"
        />
        <%!-- The snapshots this credential can see. Hetzner has no image upload, so these are
              ones the operator made by hand; the platform offers what is there and never makes
              one. Free text when the provider lists none, so a node can still name a path it
              has. --%>
        <.input
          :if={@images != []}
          field={@form[:image]}
          type="select"
          label="Image"
          options={
            [
              blank_choice(@required, :image, "the node's default"),
              {latest_label(Provisioning.current_image(@images)), Template.latest()}
            ] ++ for(i <- @images, do: {image_label(i, @current_build), i.id})
          }
        />
        <.input
          :if={@images == []}
          field={@form[:image]}
          type="text"
          label="Image"
          autocomplete="off"
        />
        <%!-- Filled by picking a size, and still the operator's to change. --%>
        <div class="template-step-pair">
          <.input field={@form[:memory]} type="text" label="Memory (e.g. 8GiB)" mono />
          <.input field={@form[:cores]} type="number" label="Cores" mono />
        </div>
      </section>

      <section class="template-step">
        <h3 class="template-step-head">
          <span class="template-step-mark">3</span> Limits
        </h3>
        <div class="template-step-line">
          <label for={"#{@id}-max"}>Max machines</label>
          <.stepper
            id={"#{@id}-max"}
            name="template[max_workers]"
            value={@form.params["max_workers"]}
            min={0}
            max={99}
          />
        </div>
        <%!-- A number field and not a stepper: blank is *the platform's default*, which a stepper
              has no way to say. --%>
        <.input
          field={@form[:idle_minutes]}
          type="number"
          label="Idle minutes"
          hint="blank: the platform's default"
          mono
        />
        <%!-- The figure the list leads with, as it changes. --%>
        <p :if={@ceiling} id={"#{@id}-ceiling"} class="template-step-ceiling">
          Up to <strong>{money(@ceiling.total, @ceiling.currency)}</strong>
          <span>{@ceiling.count} × {money(@ceiling.each, @ceiling.currency)}</span>
        </p>
      </section>

      <section class="template-step">
        <h3 class="template-step-head">
          <span class="template-step-mark">4</span> Takes
        </h3>
        <p class="template-step-note">Nothing ticked means any kind.</p>
        <%!-- **Checked from the form's own params**, or editing a template that takes only
              workflow jobs would render the boxes empty and save it as taking any kind. --%>
        <div class="template-kinds">
          <.choice_row
            :for={kind <- Forge.Jobs.Job.kinds()}
            name={"template[accepts_#{kind}]"}
            value="true"
            label={to_string(kind)}
            multi
            selected={@form.params["accepts_#{kind}"] == "true"}
          />
        </div>
      </section>
    </div>

    <%!-- The way out is outside the part that hides: a template whose provider has no credential
          shows no fields at all, and a form you cannot leave is worse than one you cannot fill
          in. Cancel and the submit side by side, as Model and effort's Discard and Save. --%>
    <div :if={@ready or @beside != []} class="template-dock">
      {render_slot(@beside)}
      <.button :if={@ready} type="submit" variant="primary" size="xl" fill>{@submit}</.button>
    </div>
    """
  end

  # The ceiling the form's figures make, from the size chosen and the maximum typed: the same
  # multiplication the list leads with, so the two cannot disagree.
  defp form_ceiling(shapes, params) do
    with size when is_binary(size) and size != "" <- params["size"],
         %{price_hourly: %Decimal{} = each, currency: currency} when is_binary(currency) <-
           Enum.find(shapes, &(&1.size == size)),
         count when is_integer(count) <- number(params["max_workers"] || "") do
      %{each: each, total: Decimal.mult(each, count), currency: currency, count: count}
    else
      _other -> nil
    end
  end

  attr :template, :map, required: true
  attr :ceiling, :any, required: true
  attr :made, :integer, required: true
  attr :projects, :list, required: true
  attr :open, :boolean, default: false
  attr :current_build, :string, default: nil

  # A template's row (`14a`, and on a wide screen `14f`'s table): its ceiling in money, its slots,
  # its identifiers and what it carries, what each machine is, and who may use it. The head is the
  # link that opens it; its failure and Enable sit under the head, outside the link.
  defp template_row(assigns) do
    assigns = assign(assigns, disabled: Provisioning.disabled?(assigns.template))

    ~H"""
    <li
      id={"template-#{@template.id}"}
      class={[
        "template",
        @disabled && "template--disabled",
        @open && "template--open"
      ]}
    >
      <.link patch={~p"/templates?template=#{@template.id}"} class="template-head">
        <span class="template-name">
          {@template.name}
          <%!-- A flag, beside the identifiers and never instead of them: `ui.md` § The three
                axes. It is the only thing on this page that is a state rather than a value. --%>
          <span :if={@disabled} class="template-flag">Disabled</span>
        </span>
        <span class="template-makes">
          <span>{names(@template)}</span>
          <%!-- What the snapshot carries: from its labels, or learnt from a machine refused at
                join (`provisioning.md` § A snapshot that speaks the wrong protocol). A template
                naming no image boots the driver's default. --%>
          <span
            :if={@template.image || @template.image_protocol}
            class={other_build?(@template, @current_build) && "text-warning"}
          >
            {carries(@template.image_build, @template.image_protocol, @current_build)}
          </span>
        </span>
        <span class="template-ceiling">
          <span :if={@ceiling}>up to {money(@ceiling.total, @ceiling.currency)}</span>
          <span :if={@ceiling} class="template-quiet">
            {@template.max_workers} × {money(@ceiling.each, @ceiling.currency)}
            <span class="whitespace-nowrap">· {monthly(@ceiling.total, @ceiling.currency)}</span>
          </span>
          <span :if={is_nil(@ceiling)} class="template-quiet">no price from the provider</span>
        </span>
        <span class="template-running"><.slots made={@made} max={@template.max_workers} /></span>
        <span class="template-what">{what(@template)}</span>
        <span class={["template-projects", @projects == [] && "text-warning"]}>
          {if @projects == [],
            do: "never used",
            else: "for " <> Enum.map_join(@projects, ", ", & &1.name)}
        </span>
        <span class="template-chevron" aria-hidden="true">›</span>
      </.link>
      <.failure template={@template} />
    </li>
    """
  end

  attr :template, :map, required: true

  # What went wrong, where the thing that went wrong is. A count below the limit is worth showing
  # too: it is the warning before the template stops being used. Enable sits with it, the one way
  # back (`provisioning.md` § A template that cannot make a working machine is taken out of
  # service).
  defp failure(assigns) do
    assigns =
      assign(assigns,
        refusal: refusal(assigns.template),
        disabled: Provisioning.disabled?(assigns.template)
      )

    ~H"""
    <p :if={@refusal} class="template-failure">
      {@refusal}: no machine is made from it until it names another
    </p>
    <p :if={@template.failures > 0} class="template-failure">
      {@template.failures} failed {if @template.failures == 1, do: "attempt", else: "attempts"}<span :if={
        @disabled
      }> — it is out of service until you enable it</span><span :if={@template.last_error}>: {@template.last_error}</span>
      <.button
        :if={@disabled}
        variant="link"
        size="sm"
        phx-click="enable-template"
        phx-value-id={@template.id}
      >
        Enable
      </.button>
    </p>
    """
  end

  defp other_build?(template, current_build),
    do: Format.build_hint(template.image_build, current_build) == "other build"

  # The subline (`14a`, `14d`, `14e`): whose, how many, and every ceiling it can add up.
  defp subline(%{view: "credentials", credentials: credentials}),
    do: "yours only · #{count(length(credentials), "credential")}"

  defp subline(%{templates: []}), do: "no templates"

  defp subline(%{templates: templates, ceilings: ceilings}) do
    case total(Map.values(ceilings)) do
      "" -> "yours only · #{count(length(templates), "template")}"
      sum -> "yours only · #{count(length(templates), "template")} · up to #{sum}"
    end
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        template: Enum.find(assigns.templates, &(&1.id == assigns.open)),
        named: Enum.frequencies_by(assigns.templates, & &1.provider_credential_id)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="Machines"
      subline={subline(assigns)}
      top_level={:machines}
      views={WorkersLive.views()}
      view={@view}
      measure={nil}
    >
      <.error_note :if={@error && is_nil(@open)} id="templates-error" class="templates-error">
        {@error}
      </.error_note>

      <div :if={@view == "templates"} class="templates-list">
        <%!-- The empty state is the feature, not decoration: with no node fallback this is the
              whole reason a new node runs nothing (`provisioning.md` § Whose account), so it is
              given the page (`14e`), with what is already done ticked. --%>
        <section :if={@templates == []} id="none-yet" class="templates-none">
          <h2>None yet, so nothing runs.</h2>
          <p class="templates-intro">
            A project makes machines from the templates assigned to it, and there is no fallback
            to the node's own settings.
          </p>
          <ol class="templates-steps">
            <li class={[
              "templates-step",
              (@credentials != [] or @credentialled == []) && "templates-step--done"
            ]}>
              <span class="template-step-mark">{if @credentials != [] or @credentialled == [],
                do: "✓",
                else: "1"}</span>
              <span class="templates-step-title">Add a credential</span>
              <span :if={@credentials != []} class="templates-step-detail">
                {Enum.map_join(@credentials, ", ", &"#{&1.name} · #{&1.provider}")}
              </span>
              <span :if={@credentials == [] and @credentialled != []} class="templates-step-detail">
                The account a machine is billed to, and its sizes and images are read from.
              </span>
              <span :if={@credentialled == []} class="templates-step-detail">
                No provider here needs one.
              </span>
            </li>
            <li class="templates-step">
              <span class="template-step-mark">2</span>
              <span class="templates-step-title">Make a template</span>
              <span class="templates-step-detail">
                What a machine is made from, and how many there may be.
              </span>
            </li>
            <li class="templates-step">
              <span class="template-step-mark">3</span>
              <span class="templates-step-title">Assign it to a project</span>
              <span class="templates-step-detail">
                {case @bare do
                  [] ->
                    "You are in no project with nothing to run on."

                  [one] ->
                    "#{one.name} has nothing to run on."

                  [first | rest] ->
                    "#{first.name} and #{length(rest)} #{if length(rest) == 1, do: "other", else: "others"} have nothing to run on."
                end}
              </span>
            </li>
          </ol>
          <.button
            :if={@credentials == [] and @credentialled != []}
            id="none-yet-next"
            variant="primary"
            patch={~p"/templates?view=credentials"}
          >
            Add a credential
          </.button>
          <.button
            :if={@credentials != [] or @credentialled == []}
            id="none-yet-next"
            variant="primary"
            patch={~p"/templates?new=1"}
          >
            Make a template
          </.button>
        </section>

        <div :if={@templates != []}>
          <p class="templates-intro">
            A template is how a machine gets made. Its values are copied at creation, so editing
            one never changes a machine that exists.
          </p>
          <div class="templates-columns" aria-hidden="true">
            <span>template</span>
            <span>makes · carries</span>
            <span>ceiling</span>
            <span>running</span>
            <span>projects</span>
            <span />
          </div>
          <ul id="templates">
            <.template_row
              :for={template <- @templates}
              template={template}
              ceiling={@ceilings[template.id]}
              made={Map.get(@counts, template.id, 0)}
              projects={Map.get(@assignments, template.id, [])}
              open={@open == template.id}
              current_build={@current_build}
            />
          </ul>
          <.button
            :if={@open != :new}
            id="new-template"
            variant="outline"
            class="templates-dock"
            patch={~p"/templates?new=1"}
          >
            + Make a template
          </.button>
        </div>
      </div>

      <div :if={@view == "credentials"} id="credentials" class="templates-credentials">
        <p class="templates-intro">
          Yours, and nobody else's. A machine made from a template is billed to the account behind
          the credential that template names.
        </p>

        <ul class="templates-credential-list">
          <li :for={credential <- @credentials} id={"credential-#{credential.id}"} class="credential">
            <div class="credential-head">
              <span class="credential-name">{credential.name}</span>
              <span class="credential-provider">{credential.provider}</span>
            </div>
            <%!-- What removing it costs, before anybody presses Remove (`14d`). --%>
            <div class="credential-liable">
              named by {count(Map.get(@named, credential.id, 0), "template")}<span :if={
                liable(@templates, @ceilings, credential.id) != ""
              }> · up to {liable(@templates, @ceilings, credential.id)}</span>
            </div>
            <.confirm
              id={"delete-credential-#{credential.id}"}
              label="Remove"
              act="Remove it"
              sentence={"Remove #{credential.name}? Templates that name it stop being able to create."}
              class="credential-remove"
              phx-click="delete-credential"
              phx-value-id={credential.id}
            />
            <.image_builds
              :if={Provider.builds?(credential.provider)}
              credential={credential}
              release={@release}
              listing={@listings[credential.id]}
              builds={@builds[credential.id] || []}
            />
          </li>
          <li :if={@credentials == []} class="templates-intro">None yet.</li>
        </ul>

        <p :if={@credentialled == []} class="templates-intro">
          No provider configured on this node needs one. A local machine is made by this host and
          there is no account to reach.
        </p>

        <.error_note :if={@error} class="templates-error">{@error}</.error_note>

        <.form
          :if={@credentialled != []}
          for={@credential_form}
          id="credential-form"
          phx-change="credential-provider"
          phx-submit="add-credential"
          class="credential-form"
        >
          <h2 class="credential-form-title">Add a credential</h2>
          <.input
            field={@credential_form[:provider]}
            type="select"
            label="Provider"
            options={@credentialled}
          />
          <.input field={@credential_form[:name]} type="text" label="Name" autocomplete="off" mono />
          <%!-- Written out rather than `<.input>`, which renders a field's value into the page.
                The id carries the provider and a sequence: a different provider's fields, or the
                form after a successful add, are new elements rather than ignored old ones. --%>
          <div
            :for={field <- Provider.credential_fields(@credential_provider)}
            class="mb-2 py-1"
            id={"credential-secret-#{@credential_provider}-#{field.key}-#{@credential_seq}"}
            phx-update="ignore"
          >
            <label for={"credential-secret-input-#{field.key}-#{@credential_seq}"}>
              <span class="mb-1.5 block text-[13px] text-ink-2">{field.label}</span>
              <input
                type="password"
                name={"credential[#{field.key}]"}
                id={"credential-secret-input-#{field.key}-#{@credential_seq}"}
                autocomplete="off"
                class="min-h-12 w-full rounded-md border border-border bg-transparent px-3 text-[14px] text-ink"
              />
            </label>
          </div>
          <p class="template-step-note">Never shown again, and never kept by this page.</p>
          <.button type="submit" variant="primary" fill>Add it</.button>
        </.form>
      </div>

      <:aside :if={@view == "templates" and @open != nil}>
        <div class="templates-aside">
          <.link patch={~p"/templates"} class="templates-back">‹ Templates</.link>
          <.error_note :if={@error} id="templates-error" class="templates-error">
            {@error}
          </.error_note>

          <%!-- Creating one: both forms are filled from `@template_form` and read one catalogue,
                so only one is ever open (`14c`). --%>
          <.form
            :if={@open == :new}
            for={@template_form}
            id="template-form"
            phx-change="template-provider"
            phx-submit="add-template"
            class="template-form"
          >
            <h2 class="templates-aside-title">Make a template</h2>
            <.template_fields
              id="template-form"
              form={@template_form}
              credentials={@credentials}
              provider={@template_provider}
              credential={@template_credential}
              providers={@providers}
              shapes={@shapes}
              images={@images}
              shapes_error={@shapes_error}
              images_error={@images_error}
              ready={@template_ready}
              required={Provider.required_template_fields(@template_provider)}
              submit="Make it"
              current_build={@current_build}
            />
          </.form>

          <.detail
            :if={@template}
            template={@template}
            ceiling={@ceilings[@template.id]}
            made={Map.get(@counts, @template.id, 0)}
            assigned={Map.get(@assignments, @template.id, [])}
            projects={@projects}
            credentials={@credentials}
            current_build={@current_build}
            editing={@editing == @template.id}
          >
            <.form
              :if={@editing == @template.id}
              for={@template_form}
              id={"edit-template-#{@template.id}"}
              phx-change="template-provider"
              phx-submit="save-template"
              class="template-form"
            >
              <.template_fields
                id={"edit-template-#{@template.id}"}
                form={@template_form}
                credentials={@credentials}
                provider={@template_provider}
                credential={@template_credential}
                providers={@providers}
                shapes={@shapes}
                images={@images}
                shapes_error={@shapes_error}
                images_error={@images_error}
                ready={@template_ready}
                required={Provider.required_template_fields(@template_provider)}
                submit="Save it"
                current_build={@current_build}
              >
                <:beside>
                  <.button type="button" variant="secondary" size="xl" phx-click="cancel-edit">
                    Cancel
                  </.button>
                </:beside>
              </.template_fields>
            </.form>
          </.detail>
        </div>
      </:aside>
    </Layouts.app>
    """
  end

  # The ceilings of every template naming a credential, added up: what removing it would stop.
  defp liable(templates, ceilings, credential_id) do
    templates
    |> Enum.filter(&(&1.provider_credential_id == credential_id))
    |> Enum.map(&ceilings[&1.id])
    |> total()
  end

  attr :template, :map, required: true
  attr :ceiling, :any, required: true
  attr :made, :integer, required: true
  attr :assigned, :list, required: true
  attr :projects, :list, required: true
  attr :credentials, :list, required: true
  attr :current_build, :string, default: nil
  attr :editing, :boolean, required: true
  slot :inner_block

  # One template, opened (`14b`): its ceiling large with the slots and what happens when they are
  # full, the machine it makes with what its image carries, its projects assigned and unassigned
  # in place, Edit, and Remove behind its confirm.
  defp detail(assigns) do
    assigns =
      assign(assigns,
        credential:
          Enum.find(assigns.credentials, &(&1.id == assigns.template.provider_credential_id)),
        full: assigns.made >= assigns.template.max_workers
      )

    ~H"""
    <section id="template-detail" class="template-detail">
      <div class="template-detail-head">
        <h2 class="templates-aside-title templates-aside-title--id">{@template.name}</h2>
        <.button
          :if={not @editing}
          variant="link"
          size="sm"
          phx-click="edit-template"
          phx-value-id={@template.id}
        >
          Edit
        </.button>
      </div>

      <%!-- Not while editing: the live ceiling in Limits is the one that changes (UX pass, D16). --%>
      <div :if={not @editing} class="template-ceiling-card">
        <.eyebrow>Ceiling</.eyebrow>
        <p :if={@ceiling} class="template-ceiling-figure">
          {money(@ceiling.total, @ceiling.currency)}
          <span>{@template.max_workers} × {money(@ceiling.each, @ceiling.currency)}</span>
        </p>
        <p :if={@ceiling} id="template-monthly" class="template-quiet">
          {monthly(@ceiling.total, @ceiling.currency)} at the ceiling, every machine running
        </p>
        <p :if={is_nil(@ceiling)} class="template-ceiling-none">
          The provider names no price for {@template.size || "this machine"}, so there is no
          figure to draw.
        </p>
        <p class="template-ceiling-slots">
          <.slots made={@made} max={@template.max_workers} />
          <span>{if @full, do: "running · new work waits", else: "running"}</span>
        </p>
        <p class="template-quiet">
          {if @template.idle_ms,
            do: "idle machines are destroyed after #{div(@template.idle_ms, 60_000)} minutes",
            else: "idle machines are destroyed after the platform's default"}
        </p>
      </div>

      <.failure template={@template} />

      {render_slot(@inner_block)}

      <div :if={not @editing} class="template-facts">
        <.eyebrow>Machine</.eyebrow>
        <.fact_list dense>
          <:fact label="provider">
            {@template.provider}{if @credential, do: " · " <> @credential.name}
          </:fact>
          <:fact label="size">
            {[@template.size, gib(@template.memory), "#{@template.cores} cores"]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" · ")}
          </:fact>
          <:fact label="image">{names(@template)}</:fact>
          <:fact
            :if={@template.image || @template.image_protocol}
            label="carries"
            tone={other_build?(@template, @current_build) && "warning"}
          >
            {carries(@template.image_build, @template.image_protocol, @current_build)}
          </:fact>
          <:fact label="takes">{kinds(@template.accepts)}</:fact>
        </.fact_list>
      </div>

      <div :if={not @editing} class="template-projects-block">
        <.eyebrow>Projects</.eyebrow>
        <.project_assign
          id="template-projects"
          assigned={@assigned}
          projects={@projects}
          assign="assign"
          unassign="unassign"
          values={[{"template", @template.id}]}
          remove="Unassign"
          none="none — this template is never used"
          none_tone="warning"
        />
      </div>

      <%!-- A page about one template: its Remove is full width and last (`ui.md` § The confirm). --%>
      <.confirm
        :if={not @editing}
        id={"delete-template-#{@template.id}"}
        label="Remove template"
        act="Remove it"
        sentence={"Remove #{@template.name}? Machines already made from it keep running."}
        size="lg"
        fill
        phx-click="delete-template"
        phx-value-id={@template.id}
      />
    </section>
    """
  end
end
