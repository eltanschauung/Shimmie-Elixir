# Shimmie-Elixir

An Elixir/Phoenix booru descended from Shimmie2, using PostgreSQL. The retained
frontend assets and compatible routes do not require PHP or Composer.

## Install

Requires Elixir 1.16+, compatible Erlang/OTP, PostgreSQL, Node.js, ImageMagick,
curl, GNU coreutils and util-linux. Provision a database and set `DATABASE_URL`.

```sh
cd phoenix_rewrite
mix deps.get --check-locked
mix assets.setup
mix assets.build
# Set SHIMMIE_BOOTSTRAP_ADMIN_NAME and SHIMMIE_BOOTSTRAP_ADMIN_PASSWORD first.
mix ecto.migrate
mix phx.server
```

There is no default administrator password. Before the first migration, choose a
12+ character password (maximum 72 UTF-8 bytes); existing administrators are never
reset. See [application configuration and security notes](phoenix_rewrite/README.md)
and [environment template](phoenix_rewrite/.env.example).

## Configuration and upgrades

PostgreSQL is the only backend. `DATABASE_URL` takes precedence over
`SHIMMIE_DATABASE_URL`. Native private JSON settings use `SHIMMIE_CONFIG_PATH`
(default: `data/config/site.json` under the asset/media root). Production also
requires `SECRET_KEY_BASE` and a separate `SHIMMIE_SECRET`, or the existing site
secret stored in that private JSON file.

When upgrading an existing instance, preserve both secrets, the warehouse split
count, enabled extensions, database, media and instance settings. Convert PHP
settings to JSON before activating the new release; PHP files and raw legacy
DSNs are no longer read. Do not regenerate secrets or move media during conversion.

The obsolete PHP implementation, Composer tooling and PHP-only container/CI setup
have been removed. Deploy a built, read-only Phoenix release behind an HTTPS
reverse proxy; do not run production from a mutable development build.

## Development

Use a disposable PostgreSQL database and media root for `mix test`. Run formatting,
the JavaScript tests under `phoenix_rewrite/test/js`, dependency audit and asset
build checks for relevant changes. Never point tests at production.

Shimmie2-derived code/assets retain their original licensing; see [LICENSE.txt](LICENSE.txt).
