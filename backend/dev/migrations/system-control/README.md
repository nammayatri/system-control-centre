# Migrations

Tables are auto-created by `ensureSchema` on app startup. These migrations are for **seed data** and **performance indexes**.

## How to run

```bash
# Run all migrations
for f in dev/migrations/system-control/0*.sql; do psql -d system_control -f "$f"; done

# Or use nix command
sc-migrate
```

## Migrations

| File | What | When to run |
|------|------|-------------|
| `0001-seed-server-config.sql` | Insert default server_config entries | Once on fresh DB |
| `0002-add-indexes.sql` | Performance indexes on all 10 tables | Once on fresh DB |

## For local testing

```bash
sc-setup-db    # Creates DB + schema + seed + indexes (all-in-one)
```
