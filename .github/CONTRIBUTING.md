# Contributing

The application is in `phoenix_rewrite/`; PostgreSQL is the only supported backend.
Keep user-facing routes, permissions, configuration and existing data compatible.

For relevant changes run:

- `mix test` against a disposable PostgreSQL database and media root.
- `mix format --check-formatted` on changed Elixir and HEEx files.
- `node --test test/js/*.cjs` for client-side behavior.
- `mix hex.audit`, locked dependency resolution and the asset build.

Preserve regression tests for authorization, sessions, CSRF, uploads, transactions
and filesystem containment. Do not publish credentials, production settings,
private security reports or user data. Keep the existing license and attribution.
