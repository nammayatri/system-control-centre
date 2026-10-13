# Migrations

Tables are created by `dev/sql-seed/system-control-seed.sql`. These migrations add **seed data** and **performance indexes**.

`sc-dev` auto-applies them on every start (idempotent — safe to re-run).

## Migrations

| File | What |
|------|------|
| `0001-seed-server-config.sql` | Default server_config entries (incl. decision engine toggles) |
| `0002-add-indexes.sql` | Performance indexes + unique constraints on all tables |
| `0010-local-test-data.sql` | Local TEST_AUTOPILOT app group + services for dev |
| `0053-release-request.sql` | Xyne release bot request state (`release_request`) — see `../../../RELEASE_BOT.md` |

## Manual application

```bash
psql -h 127.0.0.1 -p 5434 -d system_control -f 0001-seed-server-config.sql
```
