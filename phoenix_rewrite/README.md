# Shimmie2 Phoenix Rewrite

Compatibility-first rewrite of Shimmie2 with the target of full feature parity.

Requires Elixir 1.16+ and a compatible Erlang/OTP release. Dependency and asset
tool versions are pinned in `mix.exs`, `mix.lock`, and `config/config.exs`.

Login proofs expire server-side and are bound to the current password hash.
Upgrading from unversioned sessions requires users to sign in again; do not rotate
`SECRET_KEY_BASE`. Logout clears this browser's credentials; changing a password
invalidates existing login proofs on all devices. Favorites require a signed-in account.

Before the first migration, set `SHIMMIE_BOOTSTRAP_ADMIN_PASSWORD` to a unique
12+ character password (at most 72 UTF-8 bytes). `SHIMMIE_BOOTSTRAP_ADMIN_NAME`
optionally changes the initial name from `admin`. There is no default password;
upgrades never reset an existing administrator.

New passwords require 12+ characters (maximum 72 UTF-8 bytes). Successful legacy
MD5 logins are upgraded to bcrypt; legacy passwords over 72 bytes require an
administrator-assisted reset. Recovery is explicitly unavailable until mail
recovery is implemented. Authentication attempts have bounded IP/account/global budgets.

Uploads require ImageMagick, curl, GNU coreutils and util-linux (`timeout`, `prlimit`).
URL import settings other than `none` use the same public-address-only, DNS-pinned
curl transport: HTTP(S), ports 80/443, no redirects or proxies. Uploaded images must
decode successfully; workers, execution time, output, pixels and memory are bounded.
There are two job slots, a 320 MiB address-space limit per tool and a 20-megapixel
decoded-image limit, sized to leave headroom in a 1 GiB application sandbox.
The configured upload limit is additionally capped at 64 MiB. ASX playlists are
not accepted as media. Failed writes remove only newly published files, never
pre-existing files. Interrupted publications retain a private manifest under
`data/.upload-staging/` for operator reconciliation; do not blindly purge orphans.

Back up the database and stop old application writers before the forward-only ID
allocation migration. It adds/advances owned sequences above existing IDs without
rewriting rows, and widens legacy password columns for bcrypt. Do not roll back to
MAX+1 writers. Existing media, credentials and instance configuration are preserved.

## Current Baseline
- Phoenix app listens on `0.0.0.0:4001` in development.
- Compatibility health endpoint: `GET /__compat/health` (enabled in `dev` and `test`; disabled by default in production)
- Parity scanner task: `mix shimmie.parity.snapshot`
- First read-compat slice implemented:
  - `GET /post/view/:image_id`
  - `GET /image/:image_id/:filename`
  - `GET /thumb/:image_id/:filename`
- Home extension slice implemented:
  - `GET /` resolves legacy `front_page`
  - `GET /home` renders legacy `title` + `home_text`
- Favorites slice implemented:
  - `POST /favourite/add/:image_id`
  - `POST /favourite/remove/:image_id`
  - Post view now shows "Favorited By" from legacy favorites tables

## Compatibility Environment
The rewrite can read legacy deployment paths and DSN from environment variables:

- `SHIMMIE_LEGACY_ROOT` (default: parent directory of this app)
- `SHIMMIE_ASSETS_DIR` (default: `$SHIMMIE_LEGACY_ROOT/assets`)
- `SHIMMIE_LEGACY_CONFIG_PATH` (default: `$SHIMMIE_LEGACY_ROOT/data/config/shimmie.conf.php`)
- `SHIMMIE_LEGACY_DSN` (optional raw legacy DSN)
- `SHIMMIE_DATABASE_URL` (optional Ecto URL override)

If `SHIMMIE_DATABASE_URL` is not set, the app attempts to parse `DATABASE_DSN` from legacy
`shimmie.conf.php` and convert PostgreSQL DSN format to an Ecto URL.

## Running Locally
1. `mix setup`
2. `mix ecto.create`
3. `mix test`
4. `mix phx.server`

Then verify:
- App: `http://localhost:4001`
- Compatibility status: `http://localhost:4001/__compat/health`

## Production Hardening Checklist
1. Use `.env.example` as a template and set real values via environment variables.
2. Do not commit `.env`, `data/`, or legacy DB files.
3. Keep `compat_health_enabled` disabled in production builds.
4. Set `SECRET_KEY_BASE` from `mix phx.gen.secret`.
5. Serve over HTTPS so auth cookies are always marked `Secure`.
6. Production binds to loopback by default; set `SHIMMIE_BIND_IP` explicitly only
   on a suitably isolated container/backend network. Preserve a tested manifest
   of any deployment-specific security overlay rather than overwriting it.
7. Provision the database separately. The runtime role does not need `CREATEDB`,
   superuser, role-management or replication privileges; schema ownership and a
   dedicated migration role should be planned separately for imported databases.

## Verification

Run `mix test`, `mix format --check-formatted` on changed Elixir/HEEx files,
`node --test test/js/*.cjs`, `mix hex.audit`, and `mix deps.get --check-locked`.
Use a disposable database and media root, never production. Coverage is a separate
assurance metric (`mix test --cover`); a passing test suite is not a claim that
the existing 90% coverage gate or a complete browser/security audit has passed.

## Parity Tracking
Run:

```bash
mix shimmie.parity.snapshot
```

This generates:
- `docs/parity_snapshot.md`
- `docs/parity_matrix.csv`

By default it filters scope to enabled extensions listed in `../extensions_enabled.txt`.
Override with `SHIMMIE_ENABLED_EXTENSIONS_FILE=/path/to/file`.
