# Permanent fix: one mobile-release row per version

## Problem
A mobile release is currently identified by `(version, mode)` — `MANUAL` (SCC create),
`STORE_SYNC` (store snapshot / promoted), `EXTERNAL_REVIEW` (review). Each is its own
row guarded by its own *disjoint* partial unique index, so one version can hold a
`STORE_SYNC` row **and** an `EXTERNAL_REVIEW` row at once (the BharatTaxi "INREVIEW
while rolling out" bug). The only thing preventing it is scattered app-level dedup
(`sccActiveReleaseExistsForVersion`) — leaky, and origin-dependent (SCC vs external).

## Target model (agreed)
Identity = `(app_group, service, env, new_version)` — **one row per version**.
`track` is a **monotonic attribute** (internal → production, never back). Four slots:

| Slot | Max | Holds |
|---|---|---|
| INTERNAL | 1 | latest built, not yet promoted |
| PROD-INCOMING | 1 | next version (in review / approved / rejected) |
| PROD-LIVE | 1 | currently serving (rolling / halted / live) |
| HISTORY | ∞ | superseded + old versions |

Rules:
- **Most-advanced-track-wins**: a version on production is never also shown as internal.
- **Rule A (live supersession):** when an approved incoming version starts rolling out,
  the previous live version freezes at its last % → `rollout_status='superseded'` →
  HISTORY, badge `Superseded · X%`.
- **Rule B (incoming auto-retire):** a newer incoming version pushes the older incoming
  (in_review / approved / rejected) to HISTORY automatically.

## Build stages
1. **Migration 0034** — `store_track` column + backfill + collapse existing same-version
   dupes (repoint events, drop redundant) + version-keyed unique index (replaces the two
   per-mode indexes).
2. **Domain module `Versioning/Slot.hs`** — pure, testable classification of a row into a
   `Slot` + lifecycle `Stage`, and the pure merge rules. Single source of truth, mirrors
   the frontend `mobileStage.ts`.
3. **`upsertMobileVersionRow`** — one convergent write keyed by `(app, surface, platform,
   version)`; all creators (store-sync snapshot, external-review, SCC create, rollout
   reflection) funnel through it (DO UPDATE merge, not parallel rows / DO NOTHING).
4. **Rules A & B** — wired into the rollout-start and promote paths via small reusable
   helpers (`supersedePreviousLive`, `retireOlderIncoming`).
5. **Frontend** — `superseded` stage + `Superseded · X%` badge in `mobileStage.ts`;
   slot-aware rendering.

## Safety
- Unique index predicate is `status <> 'COMPLETED' OR rollout_status IS NOT NULL`
  (one *active* row per version) so COMPLETED history + reverts of old versions are exempt.
- Backfill collapses to one row per version for display cleanliness; the upsert keeps it so.
- Prod DB is migrated via the migration system; only local dev DB is mutated directly here.
