# 2026-07-27 `Scope.admin?/1` Deprecation Migration

## Scope

Replacing the deprecated `PhoenixKit.Users.Auth.Scope.admin?/1` in the
dep-side packages that call it. Filed here rather than under
`dev_docs/pull_requests/` because there is no PR — the change landed directly
on `main` as `e467bce`, and `pull_requests/README.md` scopes out changes this
small anyway ("simple dependency updates").

**Affected packages** (both were on their latest Hex release when this
started, so the fix required new releases rather than a version bump):

| Package | Was | Status |
|---|---|---|
| `phoenix_kit_ai` | 0.17.0 | ✅ fixed, 0.17.1 (this repo) |
| `phoenix_kit_entities` | 0.2.8 | ⬜ not done — separate checkout |

## Why This Mattered

`phoenix_kit` 1.7.214 renamed `Scope.admin?/1` to
`Scope.can_access_admin_area?/1` (PR #665) and left the old name as a
`@deprecated` alias:

```elixir
# deps/phoenix_kit/lib/phoenix_kit/users/auth/scope.ex:335-337
@deprecated "Use can_access_admin_area?/1 — `admin?` is true for ANY permission holder, not just the Admin role."
@spec admin?(t()) :: boolean()
def admin?(scope), do: can_access_admin_area?(scope)
```

The rename was semantic, not behavioral. `can_access_admin_area?/1`
(`scope.ex:319-327`) returns `true` when the scope holds the Admin **or** Owner
role, **or** holds any non-empty permission set at all — so the old `admin?`
name read as a role check when it was really an access check.

The practical problem was that the warning fired in **host** applications, on
every compile, pointing at a line inside a dependency. Host authors could
neither fix nor silence it. That is what this change addresses.

## The Trap: This Is Not Warnings-Only

The brief that initiated this work characterized it as a safe mechanical
substitution — true for the *call*, but incomplete for the *package*.

`mix.exs` pinned `pk_dep(:phoenix_kit, ">= 1.7.196")`. The replacement function
does not exist below **1.7.214**. Shipping the rename against the old floor
would trade a compile-time deprecation warning for a **runtime
`UndefinedFunctionError`** on any host that happened to resolve phoenix_kit in
the 1.7.196–1.7.213 range — a strictly worse failure, and one that would only
surface when an admin LiveView actually mounted.

**The floor bump is mandatory, not cosmetic.** Anyone applying this same fix to
`phoenix_kit_entities` must raise that package's `phoenix_kit` requirement to
`>= 1.7.214` in the same commit.

## Changes Made (`phoenix_kit_ai`)

### 1. The call site — `lib/phoenix_kit_ai/web/auth_helpers.ex:49`

```elixir
  def admin?(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      nil -> false
-     scope -> Scope.admin?(scope)
+     scope -> Scope.can_access_admin_area?(scope)
    end
  end
```

This was the only call site in the repo (`grep -rn "admin?"` across `lib/`,
`test/`, excluding `deps/` and `_build/`).

### 2. The floor — `mix.exs`

```elixir
+ # 1.7.214+ required: Scope.can_access_admin_area?/1 (the rename of the
+ # now-`@deprecated` Scope.admin?/1) — an older core has no such function,
+ # so this is an UndefinedFunctionError at runtime, not a warning.
- pk_dep(:phoenix_kit, ">= 1.7.196"),
+ pk_dep(:phoenix_kit, ">= 1.7.214"),
```

`mix.lock` already resolved 1.7.216, so no `deps.get` churn.

### 3. The local wrapper's doc — `auth_helpers.ex:37-44`

`PhoenixKitAI.Web.AuthHelpers.admin?/1` **keeps its name**. It is public API of
this library, and it feeds the `"admin" | "user"` `actor_role` string that
`actor_opts/1` threads into every mutating context call — renaming it would be
a breaking change buying nothing.

But its `@doc` said *"Returns `true` when the socket's scope reports admin
role"* — which is precisely the misreading core renamed the function to kill.
Corrected to state that it reports admin-*area* access, true for any permission
holder rather than only the Admin role.

This is worth flagging for the entities migration too: a mechanical
find-and-replace fixes the call but leaves any such doc/comment lying about
what the predicate means.

### 4. Test comments

Two coverage tests quote the call they pin, and were updated to match:

- `test/phoenix_kit_ai/web/prompt_form_coverage_test.exs:72`
- `test/phoenix_kit_ai/web/endpoint_form_coverage_test.exs:854`

No test *logic* changed. Because the old name is a pure delegate, no assertion
could have distinguished the two — which is also why the test suite passing is
weak evidence here, and the floor bump is what actually needed reasoning about.

## Verification Run

| Check | Command | Result |
|---|---|---|
| Compile | `mix compile --force --warnings-as-errors` | ✅ no warnings |
| Format | `mix format --check-formatted` | ✅ |
| Linter | `mix credo --strict` | ✅ 1102 mods/funs, no issues |
| Type checker | `mix dialyzer` | ✅ 0 errors |
| Test suite | `mix test` | ✅ 332 tests, 0 failures (545 excluded) |
| Unused deps | `mix deps.unlock --check-unused` | ✅ |

That is the full `mix precommit` gate minus `mix hex.audit`, which was not run.

## Release

Bumped to **0.17.1** with a CHANGELOG entry. Not published to Hex as of this
writing — the fix is inert for host apps until it is.

## Follow-Up for `phoenix_kit_entities`

Not done here; that repo is a separate checkout. Checklist:

1. `grep -rn "Scope.admin?" lib/ test/` — the originating brief named
   `phoenix_kit_ai` as having 1 site but did not enumerate the entities sites,
   so they still need to be found rather than assumed.
2. Replace each with `Scope.can_access_admin_area?/1`.
3. **Raise the `phoenix_kit` floor to `>= 1.7.214`** — see the trap above.
4. Check any local wrapper's `@doc`/`@spec` for the same "admin role" wording.
5. Run the gate, bump from 0.2.8, publish.

## Related

- phoenix_kit CHANGELOG 1.7.214 → the `### Changed` entry for the rename, which
  also notes: for a genuine "can do everything, like Owner" check, the right
  call is `holds_all_enabled_permissions?/1` or `superadmin?/1` — neither of
  which is what this library wants. `can_access_admin_area?/1` is the correct
  target here.
