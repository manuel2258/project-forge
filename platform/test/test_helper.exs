ExUnit.start()
ExUnit.after_suite(fn _result -> Forge.GitFixtures.drop_seed_cache() end)
Ecto.Adapters.SQL.Sandbox.mode(Forge.Repo, :manual)

# The endpoint listens on a port the kernel picked (`config/test.exs`); say which, to everything
# that builds a URL to it (`Forge.TestEndpoint`).
Forge.TestEndpoint.publish()
