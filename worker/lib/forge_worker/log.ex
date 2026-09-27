defmodule ForgeWorker.Log do
  @moduledoc """
  This machine's own lines for its log on the platform (`docs/design/worker-log.md`): a job it
  took on and how it ended, a seed it fetched or could not, a harness that would not describe
  itself, a message from a platform a version apart. **Worker-level only**: what an agent does
  inside a job is that job's event stream, and nothing here copies it.

  `line/4` writes the line to the journal as before and hands it to the link, which pushes it as
  `log` — from whichever process the line came from, so that every message on the socket still
  leaves from one place (`ForgeWorker.Link`). While the link is not joined it holds the lines,
  bounded by `hold/2`, and sends them at the next join with `drain/1`.
  """

  require Logger

  @held 100

  @typedoc "Lines held while not joined, oldest first, and how many were dropped to hold them."
  @type held :: {[map()], non_neg_integer()}

  @doc """
  Writes a line to the journal and hands it to the link. `job_id:` ties it to a job. Stamped with
  this machine's clock, which is the time it happened even if it reaches the platform later.
  """
  @spec line(String.t(), :info | :warning | :error, String.t(), keyword()) :: :ok
  def line(type, level, message, opts \\ []) do
    job_id = Keyword.get(opts, :job_id)

    # The journal has no `job_id` column, so a line about a job names it: "took on a workflow
    # job, attempt 2" is otherwise a line that cannot be tied to one.
    Logger.log(level, if(job_id, do: "job #{job_id}: #{message}", else: message))

    entry =
      %{"at" => now(), "type" => type, "level" => Atom.to_string(level), "message" => message}
      |> put_job(job_id)

    case Process.whereis(ForgeWorker.Link) do
      nil ->
        :ok

      link ->
        send(link, {:log, entry})
        :ok
    end
  end

  @doc "Nothing held."
  @spec empty() :: held()
  def empty, do: {[], 0}

  @doc """
  Holds a line while the platform is away: the last hundred, **oldest dropped first**, counting
  each one dropped so the platform can be told how many.
  """
  @spec hold(held(), map()) :: held()
  def hold({lines, dropped}, entry) when length(lines) < @held, do: {lines ++ [entry], dropped}
  def hold({[_oldest | lines], dropped}, entry), do: {lines ++ [entry], dropped + 1}

  @doc """
  What to send at the join, in order: a `log.dropped` line first when anything was, then the lines
  held, oldest first.
  """
  @spec drain(held()) :: [map()]
  def drain({lines, 0}), do: lines

  def drain({lines, dropped}) do
    [
      %{
        "at" => now(),
        "type" => "log.dropped",
        "level" => "warning",
        "message" =>
          "#{dropped} line(s) could not be kept while the platform was away; these are the " <>
            "last #{@held}"
      }
      | lines
    ]
  end

  @doc """
  How long a job ran, as the log says it: `4s`, `12m 3s`, `2h 5m`.
  """
  @spec ran(non_neg_integer()) :: String.t()
  def ran(ms) do
    s = div(ms, 1000)

    cond do
      s < 60 -> "#{s}s"
      s < 3600 -> "#{div(s, 60)}m #{rem(s, 60)}s"
      true -> "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
    end
  end

  defp put_job(entry, nil), do: entry
  defp put_job(entry, job_id), do: Map.put(entry, "job_id", job_id)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
