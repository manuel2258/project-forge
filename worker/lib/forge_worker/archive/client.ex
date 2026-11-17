defmodule ForgeWorker.Archive.Client do
  @moduledoc """
  The archive door from the worker's side: two listings and one download, authorised by the job's
  own git token as a bearer header (`docs/design/archive.md` § The door and its grant).

  **Every failure is a word the agent can act on** — an errno, because the kernel hands it to the
  agent's `open` — and **a download is bounded**: connecting takes at most `:archive_connect_ms`
  (10 s; the one bound with no test) and the transfer may not go silent for `:archive_receive_ms`
  (30 s). That is no progress,
  not total size, so a gigabyte is not cut short while a stalled one is. A body is written to a
  file of its own, checked against the size and the hash the listing promised, and only then moved
  to where a read will find it: a failed or short fetch leaves nothing that looks complete.

  **A busy platform is waited out, for at most `:bound_ms` (30 s) a read.** `429`, `502`, `503` and
  `504` are not an answer about the file: the proxy in front of the platform turns a burst away,
  or a platform restarting is not there yet. The request is asked again after the `Retry-After`
  the answer names, or, when it names none, after a pause that doubles each time, and every pause
  carries a random addition so that the reads of one `grep -r` do not all come back together.
  When the bound is gone, or a `Retry-After` would take the read past it, the read is
  `ETIMEDOUT` and the last status goes with it as the third element (`docs/design/archive.md`
  § A failed read is bounded and says why). Nothing else is asked twice: `401`, `403`, `404` and
  `500` are answers, and the same URL is asked each time with the same token and no redirect.
  """

  @type config :: %{url: String.t(), token: (-> String.t())}
  @type errno :: :enoent | :eacces | :eio | :etimedout
  @typedoc "A read that gave up waiting: a timeout, and the busy status that was the last answer."
  @type gave_up :: {:error, :etimedout, pos_integer()}

  # What a proxy answers while it is limiting, or while the platform behind it is restarting.
  @busy [429, 502, 503, 504]
  @first_pause_ms 250
  @bound_ms 30_000

  @doc "The root listing (`:root`) or one ticket's (`{:ticket, number}`)."
  @spec listing(config(), :root | {:ticket, String.t()}) ::
          {:ok, map()} | {:error, errno()} | gave_up()
  def listing(config, key) do
    path = if key == :root, do: "/archive", else: "/archive/tickets/" <> elem(key, 1)

    case get(config, path, []) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 200}} -> {:error, :eio}
      {:ok, response} -> {:error, errno(response)}
      {:busy, status} -> {:error, :etimedout, status}
      {:error, reason} -> {:error, transport(reason)}
    end
  end

  @doc """
  Downloads version `ref` of ticket `number` to `destination`, which is only written when the bytes
  are what the listing said they would be (`entry` carries `size` and `sha256`).
  """
  @spec fetch(config(), String.t(), entry :: map(), Path.t()) ::
          :ok | {:error, errno()} | gave_up()
  def fetch(config, number, %{"ref" => ref} = entry, destination) do
    partial = destination <> ".partial"
    File.mkdir_p!(Path.dirname(destination))

    try do
      case get(config, "/archive/tickets/#{number}/#{ref}", into: File.stream!(partial)) do
        {:ok, %{status: 200}} -> settle(partial, entry, destination)
        {:ok, response} -> {:error, errno(response)}
        {:busy, status} -> {:error, :etimedout, status}
        {:error, reason} -> {:error, transport(reason)}
      end
    after
      File.rm(partial)
    end
  end

  defp settle(partial, entry, destination) do
    with {:ok, %File.Stat{size: size}} <- File.stat(partial),
         true <- size == entry["size"],
         true <- hash_matches?(partial, entry["sha256"]),
         :ok <- File.rename(partial, destination) do
      :ok
    else
      _damaged -> {:error, :eio}
    end
  end

  defp hash_matches?(_path, nil), do: true

  defp hash_matches?(path, sha256) do
    digest =
      path
      |> File.stream!(1024 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    digest == sha256
  end

  # One read: asked again while the answer is busy, until the bound. `{:busy, status}` is the
  # last busy answer, given up on.
  defp get(config, path, opts) do
    retry = Application.get_env(:forge_worker, :archive_retry, [])
    clock = Keyword.get(retry, :clock, fn -> System.monotonic_time(:millisecond) end)
    bound = Keyword.get(retry, :bound_ms, @bound_ms)
    attempt(config, path, opts, %{retry: retry, clock: clock, bound: bound, started: clock.()}, 0)
  end

  defp attempt(config, path, opts, patience, tries) do
    case request(config, path, opts) do
      {:ok, %{status: status} = response} when status in @busy ->
        case pause(response, tries, patience) do
          {:wait, ms} ->
            sleep(patience.retry, ms)
            attempt(config, path, opts, patience, tries + 1)

          :give_up ->
            {:busy, status}
        end

      other ->
        other
    end
  end

  # How long to wait before asking again, or that there is no time for it. `Retry-After`, when it
  # is whole seconds and more than none, is a floor that is never undercut; without one the pause
  # doubles with every try. Either way a random addition, up to half of it, keeps reads that were
  # turned away together from coming back together.
  defp pause(response, tries, %{retry: retry, clock: clock, bound: bound, started: started}) do
    left = bound - (clock.() - started)
    named = retry_after_ms(response)
    floor = named || @first_pause_ms * Integer.pow(2, tries)
    jitter = jitter(retry, div(floor, 2))

    cond do
      left <= 0 -> :give_up
      # A named wait that does not fit is not waited for at all: the read fails now, not later.
      named && named > left -> :give_up
      # An unnamed one is cut to what is left, so that the platform gets the whole bound to return.
      true -> {:wait, min(floor + jitter, left)}
    end
  end

  # Whole seconds only. `Retry-After` is also allowed to be an HTTP date, and anything at all can
  # arrive from a network: what is not plainly a count of seconds is not a command, and the
  # backoff stands in for it. A huge number is a number, and the bound is what refuses it.
  defp retry_after_ms(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         true <- Regex.match?(~r/\A[0-9]+\z/, value),
         seconds when seconds > 0 <- String.to_integer(value) do
      seconds * 1_000
    else
      _not_a_wait -> nil
    end
  end

  # **Equivalent mutants**: the default `:rand` source and the real `Process.sleep` are the
  # production values of seams the client tests replace (the server tests run on them, with a bound
  # of 40 ms). Which number in `0..half` the default draws, and that it really sleeps, is not
  # something a test can tell from another number in the same range.
  defp jitter(retry, max) do
    case Keyword.get(retry, :jitter) do
      nil -> :rand.uniform(max + 1) - 1
      fun -> fun.(max)
    end
  end

  defp sleep(retry, ms), do: Keyword.get(retry, :sleep, &Process.sleep/1).(ms)

  defp request(%{url: url, token: token}, path, opts) do
    options =
      [
        url: String.trim_trailing(url, "/") <> path,
        headers: [{"authorization", "Bearer " <> token.()}],
        retry: false,
        redirect: false,
        # **The connect bound is untested**: a plug has no connection to time out, and a real one
        # would need a route that swallows packets. Removing it or setting it to 1 ms fails nothing.
        # The transfer bound below is tested against a socket that accepts and says nothing.
        connect_options: [
          timeout: Application.get_env(:forge_worker, :archive_connect_ms, 10_000)
        ],
        receive_timeout: Application.get_env(:forge_worker, :archive_receive_ms, 30_000)
      ] ++ opts

    Req.get(Keyword.merge(options, Application.get_env(:forge_worker, :req_options, [])))
  end

  defp errno(%{status: status}) when status in [401, 403], do: :eacces
  defp errno(%{status: 404}), do: :enoent
  defp errno(_response), do: :eio

  # A platform that is not answering, or stopped answering, is a timeout to the agent whether the
  # socket refused, closed or went quiet: it will be there later, and it should try later.
  defp transport(_reason), do: :etimedout
end
