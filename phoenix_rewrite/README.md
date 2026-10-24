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
