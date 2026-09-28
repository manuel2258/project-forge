defmodule ForgeWorker.Job.Credential do
  @moduledoc """
  The credential a job brings with it, as the harness driver is given it.

  `docs/design/credentials.md` § Delivery to the machine. The assignment carries the secret sealed
  for this worker and this job (`ForgeCore.Job.Credential`), and **it is opened only when the
  harness is spawned**, inside the zero-arity function `ForgeWorker.Harness` already accepts so a
  secret never sits in process state. The link, the job's task, the conversation process and the
  runner hold ciphertext; a crash report of any of them prints ciphertext.

  The key is this machine's own token, read from `ForgeWorker.Config` when the function runs
  rather than captured in it, so the closure holds nothing that opens anything.

  **An assignment with no credential gives the harness none**, whatever the release's own
  configuration says. A machine used to boot with the node's token and spend it on every job; a
  job the platform recorded against one credential and ran on another would make the spend a
  credential shows a claim nothing checked.
  """

  alias ForgeCore.Job.Credential, as: Sealed
  alias ForgeWorker.{Config, Log}

  # What the platform calls a kind, and what `ForgeWorker.Harness.ClaudeCode` is handed. A map and
  # not `String.to_existing_atom/1`: the wire says which of these it is, and nothing else.
  @kinds %{"api_key" => :api_key, "oauth" => :oauth}

  @doc """
  `harness_opts` with the job's credential in it, for a harness whose driver is `driver`: a
  function that opens it, or none at all.
  """
  @spec put(keyword(), map(), String.t()) :: keyword()
  def put(harness_opts, assignment, driver) do
    case assignment do
      %{
        "job_id" => job_id,
        "credential" => %{"harness" => ^driver, "kind" => kind, "sealed" => sealed}
      }
      when is_map_key(@kinds, kind) and is_binary(sealed) ->
        kind = Map.fetch!(@kinds, kind)
        Keyword.put(harness_opts, :credential, fn -> open(kind, sealed, job_id) end)

      _no_credential_for_this_harness ->
        Keyword.delete(harness_opts, :credential)
    end
  end

  # Runs in the runner, at spawn. A credential that will not open is a harness that runs without
  # one and fails *Not logged in* — said here once, without a byte of what was sealed.
  defp open(kind, sealed, job_id) do
    with {:ok, token_hash} <- Sealed.token_hash(Config.token()),
         {:ok, secret} <- Sealed.open(sealed, token_hash, job_id) do
      {kind, secret}
    else
      :error ->
        Log.line(
          "credential.unopened",
          :error,
          "the credential would not open; running without one",
          job_id: job_id
        )

        nil
    end
  end
end
