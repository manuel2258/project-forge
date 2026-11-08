defmodule Forge.Look do
  @moduledoc """
  The runner behind `bin/look`: open the platform in headless Chromium as a fixture user and run a
  list of steps (`Forge.Look.Steps`), failing on what a machine can see (`docs/design/look.md`).

  Called in-process by `mix forge.look` and by the gate's browser test, so the test exercises the
  code an agent runs. It starts the browser with every request but the app's own sent to a dead
  proxy, so an outside navigation does not load; refuses a visit that is not a path before a
  browser exists; and checks after every step what the page could not tell it itself — the
  server's errors (`Forge.Look.Watch`), the page's origin, a script error, a LiveView that never
  connected, and at phone width a page wider than the phone.

  Prints one line per step and, on a failure, its number, the step as written and the reason. It
  never prints the guard token or the login token: both are redacted from every reason, since a
  library's error message may quote a request.
  """

  alias Forge.Look.{Guard, Steps, Watch}
  alias Wallaby.{Browser, Query}

  @max_height 12_000
  @connect_ms 5_000

  @type result ::
          :ok
          | {:failed, non_neg_integer, String.t(), String.t()}
          | {:could_not_run, String.t()}

  @doc """
  Run `steps` against the app at `:base_url`.

  Options: `:base_url`; `:token` (the guard's, set as the `_forge_look` cookie); `:login_token`
  (a user's magic-link token); `:paths` (named paths a `visit :name` may use); `:io` (where
  progress goes, default `:stdio`); `:wait` (milliseconds a `wait` or a lookup may take, default
  5000); `:chromium` and `:chromedriver` (paths, default from `FORGE_CHROMIUM` and
  `FORGE_CHROMEDRIVER`, then `PATH`).
  """
  @spec run([Steps.step()], keyword) :: result
  def run(steps, opts) do
    io = Keyword.get(opts, :io, :stdio)
    secrets = Enum.reject([opts[:token], opts[:login_token]], &is_nil/1)

    with {:ok, steps} <- resolve(steps, Keyword.get(opts, :paths, %{})) |> print_failure(io),
         {:ok, session} <- start(opts) do
      try do
        case login(session, opts) do
          :ok -> run_steps(steps, session, opts, io, secrets)
          {:error, reason} -> {:could_not_run, redact("could not log in: " <> reason, secrets)}
          {:page, reason} -> failed_login(redact(reason, secrets), io)
        end
      after
        Watch.detach()
        Wallaby.end_session(session)
      end
    end
  end

  # -- before a browser exists ------------------------------------------------------------------

  @doc false
  @spec resolve([Steps.step()], %{optional(String.t()) => String.t()}) ::
          {:ok, [Steps.step()]} | {:failed, pos_integer, String.t(), String.t()}
  def resolve(steps, paths) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, acc} ->
      case resolve_step(step, paths) do
        {:ok, step} -> {:cont, {:ok, [step | acc]}}
        {:error, reason} -> {:halt, {:failed, step.n, step.text, reason}}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.reverse(steps)}
      failed -> failed
    end
  end

  defp print_failure({:failed, n, text, reason} = failed, io) do
    IO.puts(io, "FAILED step #{n}: #{text}\n  #{reason}")
    failed
  end

  defp print_failure(other, _io), do: other

  defp resolve_step(%{op: {:visit, {:named, name}}} = step, paths) do
    with {:ok, path} <- Map.fetch(paths, name) |> or_error("the setup has no path named #{name}"),
         :ok <- Steps.check_path(path) do
      {:ok, %{step | op: {:visit, {:path, path}}}}
    end
  end

  defp resolve_step(step, _paths), do: {:ok, step}

  defp or_error({:ok, _} = ok, _), do: ok
  defp or_error(:error, reason), do: {:error, reason}

  defp start(opts) do
    chromium = executable(opts[:chromium], "FORGE_CHROMIUM", "chromium")
    driver = executable(opts[:chromedriver], "FORGE_CHROMEDRIVER", "chromedriver")

    with {:ok, chromium} <- chromium,
         {:ok, driver} <- driver do
      configure(chromium, driver, opts)
      start_session()
    else
      {:error, reason} -> {:could_not_run, reason}
    end
  end

  # An explicit path, then the devshell's variable, then `PATH`: and it has to exist.
  defp executable(given, variable, name) do
    path = given || System.get_env(variable) || System.find_executable(name)

    if is_binary(path) and File.exists?(path),
      do: {:ok, path},
      else: {:error, "no #{name}: #{variable} names #{inspect(path)}"}
  end

  defp configure(chromium, driver, opts) do
    %URI{host: host, port: port} = URI.parse(Keyword.fetch!(opts, :base_url))

    args =
      [
        "--headless",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--no-first-run",
        "--hide-scrollbars",
        # Every request but the app's own goes to a port nothing listens on, so a link or a
        # redirect to elsewhere does not load. `<-loopback>` removes the implicit bypass of
        # loopback, so other loopback ports (another job's) are refused too.
        "--proxy-server=127.0.0.1:1",
        "--proxy-bypass-list=<-loopback>;#{host}:#{port}"
      ] ++ sandbox_args()

    Application.put_env(:wallaby, :chromedriver,
      path: driver,
      binary: chromium,
      capabilities: %{
        unhandledPromptBehavior: "accept",
        loggingPrefs: %{browser: "ALL"},
        chromeOptions: %{args: args, binary: chromium}
      }
    )

    Application.put_env(:wallaby, :max_wait_time, Keyword.get(opts, :wait, 5_000))
    Application.put_env(:wallaby, :screenshot_on_failure, false)
    # Wallaby prints the browser's console to standard output by default, which is noise a look's
    # line per step drowns in, and a page's console may carry a URL with a token in it.
    Application.put_env(:wallaby, :js_logger, nil)
  end

  # Chromium's own sandbox needs user namespaces, which some machines refuse. `FORGE_LOOK_NO_SANDBOX=1`
  # turns it off for the browser that then loads only the app's made-up pages inside a network
  # namespace; it is never the default.
  defp sandbox_args,
    do: if(System.get_env("FORGE_LOOK_NO_SANDBOX") == "1", do: ["--no-sandbox"], else: [])

  defp start_session do
    case Application.ensure_all_started(:wallaby) do
      {:ok, _} ->
        try do
          case Wallaby.start_session() do
            {:ok, session} ->
              {:ok, session}

            {:error, reason} ->
              {:could_not_run, "the browser would not start: " <> inspect(reason)}
          end
        rescue
          e -> {:could_not_run, "the browser would not start: " <> Exception.message(e)}
        end

      {:error, {:wallaby, reason}} ->
        {:could_not_run, "the browser or its driver is unusable: " <> inspect(reason, limit: 8)}

      {:error, reason} ->
        {:could_not_run, "the browser or its driver is unusable: " <> inspect(reason, limit: 8)}
    end
  end

  # -- logging in -------------------------------------------------------------------------------

  # The first request is refused by the guard (a 403 page has the app's origin all the same,
  # which is what a cookie needs); then the token goes in, then the user's own magic link, so the
  # app's login is what runs and not a shortcut around it.
  defp login(session, opts) do
    base = opts[:base_url]
    Watch.attach()

    try do
      session |> Browser.visit(base <> "/")

      if opts[:token],
        do: Browser.set_cookie(session, Guard.cookie(), opts[:token], httpOnly: true)

      if opts[:login_token] do
        session |> Browser.visit(base <> "/users/log-in/" <> opts[:login_token])
        session |> Browser.click(Query.css("#login_form button", at: 0, count: nil, minimum: 1))
        wait_for_path(session, "/users/log-in/", false)
      end

      _ = Watch.drain()
      :ok
    rescue
      e ->
        reason = Exception.message(e) <> " (on #{where(session)})"

        # **A page that breaks is the change's fault and not the machine's.** The login page is the
        # first to load the app's script, so a script error shared by every page, or a crash the
        # platform reports, lands here first; reported as "could not run" it would be excused as a
        # fault of the machine (exit 2) instead of failing the run (exit 1).
        case Watch.drain() do
          [] when not is_struct(e, Wallaby.JSError) -> {:error, reason}
          events -> {:page, reason <> platform_said(events)}
        end
    end
  end

  defp platform_said([]), do: ""
  defp platform_said(events), do: "; the platform reported: " <> Enum.join(events, "; ")

  defp where(session) do
    path = Browser.current_path(session)
    body = session |> Browser.page_source() |> String.replace(~r/\s+/, " ")
    error = if match = Regex.run(~r/ERR_[A-Z_]+/, body), do: " (" <> hd(match) <> ")", else: ""
    "#{path}: #{String.slice(body, 0, 200)}#{error}"
  rescue
    e -> "a page that would not say (#{Exception.message(e) |> String.slice(0, 200)})"
  end

  defp wait_for_path(session, prefix, expect_on, tries \\ 50) do
    on? = session |> Browser.current_path() |> String.starts_with?(prefix)

    cond do
      on? == expect_on -> :ok
      tries == 0 -> raise "the login did not complete"
      true -> Process.sleep(100) && wait_for_path(session, prefix, expect_on, tries - 1)
    end
  end

  defp failed_login(reason, io) do
    IO.puts(io, "FAILED while logging in:\n  #{reason}")
    {:failed, 0, "log in", reason}
  end

  # -- the steps --------------------------------------------------------------------------------

  defp run_steps(steps, session, opts, io, secrets) do
    state = %{width: :desktop, base: opts[:base_url]}
    total = length(steps)

    Enum.reduce_while(steps, {:ok, state}, fn step, {:ok, state} ->
      step = %{step | text: redact(step.text, secrets)}
      IO.puts(io, "step #{step.n}/#{total}: #{step.text}")

      case guarded(step, session, state, io) do
        {:ok, state} ->
          {:cont, {:ok, state}}

        {:error, reason} ->
          reason = redact(reason, secrets)
          IO.puts(io, "FAILED step #{step.n}: #{step.text}\n  #{reason}")
          {:halt, {:failed, step.n, step.text, reason}}
      end
    end)
    |> case do
      {:ok, _} ->
        IO.puts(io, "ok: #{total} steps")
        :ok

      failed ->
        failed
    end
  end

  defp guarded(step, session, state, io) do
    state = apply_step(step.op, session, state, io)
    after_step(step.op, session, state)
  rescue
    e -> {:error, clip(Exception.message(e))}
  catch
    {:look_failed, reason} -> {:error, reason}
  end

  defp apply_step({:width, width}, session, state, _io) do
    {w, h} = Steps.size(width)
    Browser.resize_window(session, w, h)
    %{state | width: width}
  end

  defp apply_step({:visit, {:path, path}}, session, state, _io) do
    Browser.visit(session, state.base <> path)
    state
  end

  defp apply_step({:click, target}, session, state, _io) do
    Browser.find(session, query(target), fn [first | _] -> Wallaby.Element.click(first) end)
    state
  end

  defp apply_step({:fill, css, value}, session, state, _io) do
    Browser.fill_in(session, Query.css(css), with: value)
    state
  end

  defp apply_step({:wait, target}, session, state, _io) do
    Browser.find(session, query(target))
    state
  end

  defp apply_step({:text, css}, session, state, io) do
    IO.puts(io, "  = " <> (session |> Browser.text(Query.css(css)) |> clip()))
    state
  end

  defp apply_step({:shot, :page, file}, session, state, _io) do
    {w, h} = Steps.size(state.width)

    height =
      session |> js("return document.documentElement.scrollHeight") |> min(@max_height) |> max(h)

    Browser.resize_window(session, w, height)

    try do
      write_png(file, session.driver.take_screenshot(session))
    after
      Browser.resize_window(session, w, h)
    end

    state
  end

  defp apply_step({:shot, {:css, css}, file}, session, state, _io) do
    element = Browser.find(session, Query.css(css))

    {:ok, %{"value" => data}} = Wallaby.HTTPClient.request(:get, element.url <> "/screenshot")
    write_png(file, Base.decode64!(data))
    state
  end

  # A text target is the deepest element holding the text itself, which is what a person points
  # at; `Wallaby.Query.text/1` would match every ancestor up to `<html>`.
  defp query({:css, css}), do: Query.css(css, count: nil, minimum: 1)

  defp query({:text, text}) do
    literal = if String.contains?(text, "\""), do: "'#{text}'", else: "\"#{text}\""
    # `normalize-space(.)` and not `text()`, which in XPath 1.0 reads only an element's first text
    # node: `<button><span class="icon"></span> Save</button>` and `Ticket <b>41</b> admitted`
    # both hold their text in more than one.
    Query.xpath(
      "//*[contains(normalize-space(.), #{literal}) and not(*[contains(normalize-space(.), #{literal})])]",
      count: nil,
      minimum: 1
    )
  end

  # A relative path is relative to where `bin/look` was run, which `bin/look` says in
  # `FORGE_LOOK_CALLER_DIR` because the task itself runs in `platform/`.
  defp write_png(file, png) do
    file = Path.expand(file, System.get_env("FORGE_LOOK_CALLER_DIR") || File.cwd!())
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, png)
  end

  # -- after every step -------------------------------------------------------------------------

  defp after_step(op, session, state) do
    # Any driver call reads the browser's log, where a script error is raised as one.
    url = Browser.current_url(session)

    with :ok <- watch(),
         :ok <- origin(url, state.base),
         :ok <- connected(op, session),
         :ok <- phone_width(state.width, session) do
      {:ok, state}
    end
  end

  defp watch do
    case Watch.drain() do
      [] -> :ok
      events -> {:error, "the platform reported: " <> Enum.join(events, "; ")}
    end
  end

  @doc false
  @spec origin(String.t(), String.t()) :: :ok | {:error, String.t()}
  def origin(url, base) do
    a = URI.parse(url)
    b = URI.parse(base)

    if {a.scheme, a.host, a.port} == {b.scheme, b.host, b.port},
      do: :ok,
      else: {:error, "navigated outside the app: " <> clip(url)}
  end

  defp connected({:visit, _}, session), do: await_connected(session, @connect_ms)
  defp connected(_op, _session), do: :ok

  defp await_connected(session, left) do
    case js(
           session,
           ~s|var m=document.querySelector('[data-phx-main]'); return m===null ? "none" : (m.classList.contains("phx-connected") ? "yes" : "no")|
         ) do
      state when state in ["none", "yes"] -> :ok
      _ when left <= 0 -> {:error, "LiveView did not connect"}
      _ -> Process.sleep(100) && await_connected(session, left - 100)
    end
  end

  defp phone_width(:phone, session) do
    [scroll, client] =
      js(
        session,
        "return [document.documentElement.scrollWidth, document.documentElement.clientWidth]"
      )

    if overflow?(scroll, client),
      do: {:error, "page is wider than the phone viewport (#{scroll}px in #{client}px)"},
      else: :ok
  end

  defp phone_width(_width, _session), do: :ok

  @doc false
  @spec overflow?(number, number) :: boolean
  def overflow?(scroll_width, client_width), do: scroll_width > client_width

  defp js(session, script) do
    ref = make_ref()
    me = self()
    Browser.execute_script(session, script, [], fn value -> send(me, {ref, value}) end)

    receive do
      {^ref, value} -> value
    after
      5_000 -> throw({:look_failed, "the browser did not answer a script"})
    end
  end

  # -- text -------------------------------------------------------------------------------------

  @doc false
  @spec redact(String.t(), [String.t()]) :: String.t()
  def redact(text, secrets), do: Enum.reduce(secrets, text, &String.replace(&2, &1, "[redacted]"))

  defp clip(text), do: String.slice(text, 0, 600)
end
