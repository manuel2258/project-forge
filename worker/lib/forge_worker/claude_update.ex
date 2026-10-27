defmodule ForgeWorker.ClaudeUpdate do
  @moduledoc """
  What the machine's Claude Code install-or-update attempt did, as the unit that ran it left it
  behind.

  `nix/worker-image.nix`'s `claude-code-update.service` runs once per boot, before the worker's
  own unit and ordered so that no job can be taken until it has finished, and writes
  `claude-code-update.json` under the worker's root: an `outcome` of `succeeded`, `failed` or
  `skipped`, the `version` it ended up with, and the `error` when there is one. This module is
  the only reader. `docs/design/worker-tier.md` § Updating a worker settles the rest.

  **It never raises and never refuses to answer.** A missing file is a worker whose image
  predates the unit, or whose unit was killed before it could write; a malformed one is a bug in
  a shell script nothing on this side can fix. Either way the machine still takes work, which is
  the same rule `ForgeWorker.Link.harness_offer/1` follows for the harness probe and
  `ForgeWorker.Job.Seed` for a seed that could not be fetched.
  """

  @status_file "claude-code-update.json"

  @doc """
  The attempt's status under `root`, or `nil` when there is nothing well-formed to report.

  Well-formed means a JSON object with a string `outcome`; the rest of the map is passed through
  as it was written, because what the operator is shown is drawn from it directly and this is
  not the place that decides what is worth drawing.
  """
  @spec status(Path.t()) :: map() | nil
  def status(root) do
    with {:ok, body} <- File.read(Path.join(root, @status_file)),
         {:ok, %{"outcome" => outcome} = status} when is_binary(outcome) <- Jason.decode(body) do
      status
    else
      _unreadable -> nil
    end
  end
end
