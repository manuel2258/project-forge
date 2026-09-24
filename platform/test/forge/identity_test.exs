defmodule Forge.IdentityTest do
  @moduledoc """
  What an OIDC login does to the user table.

  `docs/design/identity.md` § Identity is `(issuer, subject)`, never email, and § What the first
  implementation settled. Three rules, and each is one somebody would reasonably get wrong:

  - the key is the pair, so one address at two issuers is two people;
  - a first login makes a **pending** account, because an issuer authenticates and does not admit;
  - an address another account already holds is refused, never adopted — adopting it is how a
    configured issuer becomes the node admin.
  """

  use Forge.DataCase, async: true

  alias Forge.Accounts
  alias Forge.Accounts.User

  defp claim(overrides \\ %{}) do
    Map.merge(
      %{
        issuer: "https://issuer.example.test",
        subject: "sub-#{System.unique_integer([:positive])}",
        email: "person#{System.unique_integer([:positive])}@example.org"
      },
      overrides
    )
  end

  describe "log_in_with_identity/1" do
    test "a first login creates a pending, confirmed account" do
      claims = claim()

      assert {:ok, %User{} = user} = Accounts.log_in_with_identity(claims)

      assert user.email == claims.email
      assert %DateTime{} = user.confirmed_at
      # The perimeter is approval and an issuer does not move it.
      assert user.approved_at == nil
      refute User.active?(user)
      refute user.node_admin
      # No password, and none is needed: `valid_password?/2` answers false for one that is nil.
      assert user.hashed_password == nil
      refute User.valid_password?(user, "anything at all")
    end

    test "and records the identity it came from" do
      claims = claim()
      {:ok, user} = Accounts.log_in_with_identity(claims)

      assert [identity] = Accounts.list_identities(user)
      assert identity.issuer == claims.issuer
      assert identity.subject == claims.subject
      assert identity.email == claims.email
      assert %DateTime{} = identity.last_login_at
    end

    test "a second login finds the same account rather than making another" do
      claims = claim()
      {:ok, first} = Accounts.log_in_with_identity(claims)
      {:ok, second} = Accounts.log_in_with_identity(claims)

      assert first.id == second.id
      assert [_one] = Accounts.list_identities(first)
    end

    # The address is display-only, so it follows what the issuer says now. Keying on it instead
    # would make this a *different* person, which is the defect the whole section is about.
    test "an address changed at the issuer follows the same account" do
      claims = claim()
      {:ok, user} = Accounts.log_in_with_identity(claims)

      assert {:ok, same} = Accounts.log_in_with_identity(%{claims | email: "renamed@example.org"})

      assert same.id == user.id
      assert [identity] = Accounts.list_identities(same)
      assert identity.email == "renamed@example.org"
    end

    # `subject` is stable only within its issuer, so the pair is the key and half of it is not.
    test "the same subject at a different issuer is a different person" do
      claims = claim()
      {:ok, first} = Accounts.log_in_with_identity(claims)

      other =
        claim(%{
          issuer: "https://other.example.test",
          subject: claims.subject,
          email: "someone-else@example.org"
        })

      assert {:ok, second} = Accounts.log_in_with_identity(other)
      refute second.id == first.id
    end

    # **The one that matters.** If this adopted the existing row, any issuer an operator has
    # configured could assert a node admin's address and be them.
    test "an address another account already holds is refused, not adopted" do
      existing = Forge.AccountsFixtures.user_fixture()

      assert {:error, :email_taken} =
               Accounts.log_in_with_identity(claim(%{email: existing.email}))

      assert Accounts.list_identities(existing) == []
    end

    test "and refusing leaves nothing behind" do
      existing = Forge.AccountsFixtures.user_fixture()
      before = Repo.aggregate(User, :count)

      assert {:error, :email_taken} =
               Accounts.log_in_with_identity(claim(%{email: existing.email}))

      assert Repo.aggregate(User, :count) == before
    end
  end

  describe "link_identity/3" do
    # The deliberate join the login refuses to make: one identity, one named account, by somebody
    # with a shell.
    test "attaches an identity to an account that already exists" do
      user = Forge.AccountsFixtures.user_fixture()

      assert {:ok, identity} =
               Accounts.link_identity(user, "https://issuer.example.test", "sub-9")

      assert identity.user_id == user.id

      assert Accounts.get_user_by_identity("https://issuer.example.test", "sub-9").id == user.id
    end

    test "and afterwards that login is that account" do
      user = Forge.AccountsFixtures.user_fixture()
      {:ok, _} = Accounts.link_identity(user, "https://issuer.example.test", "sub-9")

      assert {:ok, same} =
               Accounts.log_in_with_identity(
                 claim(%{issuer: "https://issuer.example.test", subject: "sub-9"})
               )

      assert same.id == user.id
    end

    # An identity already spoken for must not be quietly moved: that would be the same takeover
    # as adopting an address, done from the host with one wrong argument.
    test "refuses to move an identity that is already somebody's" do
      first = Forge.AccountsFixtures.user_fixture()
      second = Forge.AccountsFixtures.user_fixture()
      {:ok, _} = Accounts.link_identity(first, "https://issuer.example.test", "sub-9")

      assert {:error, :already_linked} =
               Accounts.link_identity(second, "https://issuer.example.test", "sub-9")

      assert Accounts.get_user_by_identity("https://issuer.example.test", "sub-9").id == first.id
    end
  end

  describe "addresses are case-insensitive" do
    @moduletag :case_insensitive_email

    # **The mechanism is the column, not any Elixir here.** `users.email` is `citext`
    # (`priv/repo/migrations/20260911201712_create_users_auth_tables.exs`), so both the unique
    # index and every `where email = ` compare without case. Nothing in `Forge.Accounts`
    # downcases anything, and it should not start: the guarantee is one mechanism in one place.
    #
    # These tests exist because that is invisible at every call site. A review of this branch
    # reported the opposite — that an issuer asserting `Admin@corp.com` against a local
    # `admin@corp.com` would make a second, visually identical account — and it was wrong, but
    # nothing in the suite said so. Changing the column to `:string` would silently make it true.
    test "an issuer cannot make a second account by changing the case" do
      {:ok, _first} = Accounts.log_in_with_identity(claim(%{email: "person@example.org"}))

      assert {:error, :email_taken} =
               Accounts.log_in_with_identity(
                 claim(%{subject: "somebody-else", email: "Person@Example.org"})
               )
    end

    test "an account is found by any casing of its address" do
      {:ok, user} = Accounts.log_in_with_identity(claim(%{email: "person@example.org"}))

      assert Accounts.get_user_by_email("PERSON@EXAMPLE.ORG").id == user.id
      assert Accounts.get_user_by_email("Person@Example.Org").id == user.id
    end

    # The column is what makes this true, so the column is asserted directly: a change of type
    # would break the guarantee everywhere at once, and the three tests above would then be
    # reporting a property the schema no longer provides.
    test "the guarantee is the citext column, and says so if that changes" do
      %{rows: [[type]]} =
        Forge.Repo.query!("SELECT udt_name FROM information_schema.columns
           WHERE table_name = 'users' AND column_name = 'email'")

      assert type == "citext"
    end

    # The host path has to agree with the issuer path, or an operator seeds an account the next
    # OIDC login cannot match and quietly duplicates.
    test "a host-made account takes the same address as the issuer would" do
      {:ok, _user} = Accounts.create_operator("Operator@Example.org", "a long enough password")

      assert Accounts.get_user_by_email("operator@example.org")

      assert {:error, :email_taken} =
               Accounts.log_in_with_identity(claim(%{email: "OPERATOR@example.ORG"}))
    end
  end

  describe "get_user_by_identity/2" do
    test "is nil for a pair nobody holds" do
      assert Accounts.get_user_by_identity("https://issuer.example.test", "nobody") == nil
    end

    test "resolves the pair to the account that holds it" do
      {:ok, user} = Accounts.log_in_with_identity(claim(%{subject: "shared"}))

      assert %{id: id} = Accounts.get_user_by_identity("https://issuer.example.test", "shared")
      assert id == user.id
    end

    # The whole rule this table exists for: the key is `(issuer, subject)`, and a subject is only
    # ever unique *within* an issuer. Without a second issuer asserting the same subject, dropping
    # the issuer from the query changes no answer and nothing notices.
    test "the same subject at another issuer is a different account" do
      {:ok, ours} = Accounts.log_in_with_identity(claim(%{subject: "shared"}))

      {:ok, theirs} =
        Accounts.log_in_with_identity(
          claim(%{issuer: "https://other.example.test", subject: "shared"})
        )

      refute ours.id == theirs.id
      assert Accounts.get_user_by_identity("https://issuer.example.test", "shared").id == ours.id
      assert Accounts.get_user_by_identity("https://other.example.test", "shared").id == theirs.id
    end
  end

  describe "list_identities/1" do
    # In an async sandbox the only rows that exist are this test's own, so a query that forgot
    # its `where` would return the same list as one that did not. A second account holding a
    # second identity is what makes the scoping assertable at all.
    test "is scoped to the account asked about, not to the node" do
      {:ok, ours} = Accounts.log_in_with_identity(claim(%{subject: "ours"}))
      {:ok, theirs} = Accounts.log_in_with_identity(claim(%{subject: "theirs"}))

      assert [%{subject: "ours"}] = Accounts.list_identities(ours)
      assert [%{subject: "theirs"}] = Accounts.list_identities(theirs)
    end

    # The accounts page asked this once per row, on mount and after every approve, suspend and
    # promote. Counted rather than eyeballed: the assertion that matters is the query count, and
    # nothing about the returned data changes when it goes back to one call per user.
    test "issuers_by_user/1 answers for every account in a single query" do
      {:ok, one} = Accounts.log_in_with_identity(claim(%{subject: "a"}))
      {:ok, two} = Accounts.log_in_with_identity(claim(%{subject: "b"}))
      {:ok, three} = Accounts.log_in_with_identity(claim(%{subject: "c"}))
      local = Forge.AccountsFixtures.user_fixture()

      users = [one, two, three, local]
      parent = self()
      handler = "issuers-query-count-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:forge, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == parent, do: send(parent, :queried)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      issuers = Accounts.issuers_by_user(users)

      assert_receive :queried
      refute_receive :queried, 50

      assert issuers[one.id] == ["https://issuer.example.test"]
      assert issuers[local.id] == []
      assert map_size(issuers) == 4
      assert Map.has_key?(issuers, two.id) and Map.has_key?(issuers, three.id)
    end

    test "is empty for an account that has never used an issuer" do
      user = Forge.AccountsFixtures.user_fixture()

      assert Accounts.list_identities(user) == []
    end
  end
end
