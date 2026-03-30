# Migrations — system-control

Place SQL migration files here. They are applied in lexicographic order.

## Naming convention

```
0001-description.sql
0002-another-description.sql
```

## Rules

- Migrations must be idempotent (use `IF NOT EXISTS`, `ON CONFLICT DO NOTHING`, etc.)
- Never modify a migration that has already been applied to production
- Each migration should be self-contained
- Include both UP logic; for reversible changes, add a comment with the DOWN SQL
