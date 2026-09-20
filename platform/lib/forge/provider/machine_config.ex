defmodule Forge.Provider.MachineConfig do
  @moduledoc """
  What a machine is told about itself: one file of `KEY=VALUE` lines, which becomes
  `/etc/forge-worker.env` in the guest.

  **Every driver produces the same bytes by the same route.** The local driver writes them onto
  a labelled disk and Hetzner passes them as the server's user data; the image reads whichever
  is there (`docs/design/worker-tier.md` § How a machine learns what it is), so a driver has
  nothing to format and nothing to parse. It lived in `Forge.Provider.LocalVm` while there was
  one driver, which made the second one either call into the first or copy it.

  The worker token and the harness credential are in here, so whatever a driver does with the
  result is a thing done to a secret.
  """

  alias Forge.Provider

  @doc """
  The lines every machine gets, whoever makes it.

  `extra` is a driver's own additions — the local driver's ssh door is the only one — appended
  after the common set so a driver can add to this without reordering it.
  """
  @spec blob(Provider.opts(), [String.t()]) :: String.t()
  def blob(opts, extra \\ []) do
    lines =
      [
        "FORGE_WORKER_ID=#{opts.worker_id}",
        "FORGE_WORKER_TOKEN=#{opts.token}",
        "FORGE_PLATFORM_URL=#{opts.platform_url}"
      ] ++
        for({name, value} <- Map.get(opts, :harness_env, []), do: "#{name}=#{value}") ++
        extra

    Enum.map_join(lines, "\n", & &1) <> "\n"
  end
end
