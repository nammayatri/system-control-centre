# Migrations

Tables are created by `dev/sql-seed/system-control-seed.sql`. These migrations add **seed data** and **performance indexes**.

`sc-dev` auto-applies them on every start (idempotent — safe to re-run).

## Migrations

| File | What |
|------|------|
| `0001-seed-server-config.sql` | Insert default server_config entries |
| `0002-add-indexes.sql` | Performance indexes on all tables |
| `0009-decision-engine-configs.sql` | Decision engine server_config entries |

## Manual application

```bash
psql -h 127.0.0.1 -p 5434 -d system_control -f 0001-seed-server-config.sql
```
