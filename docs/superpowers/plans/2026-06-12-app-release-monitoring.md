# App Release Monitoring — Design & Build Plan

> **⚠️ Superseded (2026-06-18) — store sync is now on-demand.** The background poller this
> doc builds on (`storeSyncLoop`, `store_sync_enabled`, `store_sync_interval_minutes`) was
> **removed**. Store sync now refreshes **on demand** (UI ↻ / page open) via
> `refreshStoreStatusOne`, bounded per app by `store_refresh_cooldown_seconds` (one Play
> edit/app/refresh; ASC token + appId caches; single-flight for concurrency). Treat the
> store-sync sections below as historical design. Current behaviour: `CLAUDE.md`
> § "Mobile store sync (on-demand)" and `docs/scc-deployment.md` §7.

> **Status:** Design locked (Tier 1). Ready to build later from this doc.
> **Date:** 2026-06-12 · **Branch base:** `mobile-release-features`
> **Related:** builds on `2026-06-09-promote-review-and-staged-rollout.md` (reuses its
> rollout/review data + store clients).

---

## 1. What we are building (in plain words)

A single **App Release Monitoring** page: a grid of cards, one per app, showing each app's
**live store state** across its tracks — Play **production** + **internal**, App Store
**production** + **TestFlight** — with version, build code, status, **rollout %**, and a
review/rollout badge. Clicking a card opens a **detail modal** (per platform, with
Production / Internal-Testing tabs) that adds the **release notes** ("What's New") for that
track's live version.

The whole page — cards **and** every modal — is served by **one API call**. The modal opens
purely client-side from data already loaded; it makes **no** request of its own.

Visual reference: dashboard = cards grid; modal = app header + ID + platform, track tabs,
version + build code + status badge, and a RELEASE NOTES block.

---

## 2. Where we are today (the starting point)

Grounding facts (verified in code), so the build doesn't re-discover them:

- **The dashboard does not exist yet.** `GET /releases/live` (`Handlers/Live.hs`,
  `LiveReleasesResp`) reflects SCC's **own** `release_tracker` rows, **not** live per-track
  store state. This is a new page + new endpoint.
- **The store reads don't carry release notes.** `Play.TrackInfo` is just
  `{ tiName, tiCode }`. `fetchPlayTracks` returns `(internal, production)` versions only;
  Play `releaseNotes` and ASC `whatsNew` / TestFlight "What to Test" are **never read**.
  These are the new data the modal needs.
- **Rollout %, review status already flow.** From the staged-rollout feature:
  `release_tracker.rollout_percent` / `rollout_status` / `review_status` are reconciled by
  the Phase-7 `StoreSync` loop; Play `getTrackRolloutState` (`PlayRolloutState`) and Apple
  `getPhasedReleaseState` / `getAscReviewState` already exist. **Rollout % is nearly free.**
- **`StoreSync` already polls the stores** every `store_sync_interval_minutes` (default 30),
  gated on `store_sync_enabled`, skipped in debug envs — it fetches `fetchPlayTracks` /
  `fetchAscVersions` and inserts synthetic COMPLETED rows. **This is the poller we extend.**
- **`app_catalog`** rows are keyed by `(name, surface, platform)` with `display_label`,
  `package_name` (Play package / iOS bundle id), `enabled`. The dashboard card groups by
  `(name, surface)` (e.g. "Namma Yatri" vs "Namma Yatri Partner") and shows the android + ios
  rows side by side. Apps with only one platform show "No iOS/Android configuration".

---

## 3. Architecture — read-through cache (one call)

```
StoreSync poller (every 30m, + on-demand ↻ per app)
        │  fetch per-track: version, code, status, rollout %, release notes
        ▼
  store_status  (DB cache, ~40 rows: apps × platforms × tracks)
        │  + drift compare vs latest release_tracker (expected_version)
        ▼
  GET /mobile/store-monitor   ──(one fast DB read)──►  dashboard grid + every modal
        ▲
        └─ POST /mobile/store-monitor/:appCatalogId/refresh  (the ↻ button → live re-poll one app)
```

**Why cache, not live-fetch-per-open:** a live Play read is `createEdit → getTrack →
deleteEdit` (3 rate-limited calls); ASC is token + lookup + localizations. 10 apps × 2
platforms × 2 tracks ≈ 40 reads per page load — untenable live. The cache makes the page
**one DB query**. Trade-off: data is up-to-N-minutes stale → mitigated by a `synced_at`
freshness badge + the ↻ manual refresh.

**Why one call returns notes too:** at this scale the full payload (≈40 tracks, each with a
short note) is **~20–30 KB** — trivially one response. The modal then renders client-side
with zero extra calls. If the catalog ever grew to 100s of apps we'd split notes into a lazy
per-app detail call; not now.

---

## 4. Tier 1 — locked-in features

All fold into the MVP because the data already exists or is one field away:

| Feature | What it shows | Source |
|---|---|---|
| **Live track state** | version + build code + status per track | extended Play/ASC reads |
| **Release notes** | "What's New" per track's live version (in the modal) | extended Play/ASC reads (new) |
| **Rollout %** | production ramp — `↗ rolling out 25%`, `⏸ halted @ 10%` | `release_tracker.rollout_percent` (Phase 7) ✅ |
| **Review/rollout badge** | `In review` / `Approved · held` / `Rejected` / `Halted` / `live (100%)` | `review_status` / `rollout_status` (Phase 6/7) ✅ |
| **Out-of-band drift** ⚠ | store live version ≠ last SCC-shipped version | `store_status` vs latest `release_tracker` |
| **Prod-behind-internal gap** | "internal ahead by N versions" | compare the two tracks (same call) |
| **Freshness + ↻ refresh** | last-synced age, amber if stale; per-app live re-poll | `synced_at` + refresh endpoint |
| **Click-through** | → the SCC release that shipped this version; deep-link to Play Console / ASC | `release_tracker` id + store-URL template |

The status badge is **lifecycle-aware**, computed from `status` + `rollout_status` +
`review_status` + `rollout_percent`:
`live` → `↗ rolling out 25%` · `⏸ halted @ 10%` · `🕓 in review` · `✗ rejected` · `✓ live (100%)`.

---

## 5. Store-read extensions (the new data)

**Play (`Versioning/Play.hs`)** — generalize the Phase-2 `getProductionTrack` /
`fetchPlayTracks` into a per-track snapshot read that parses the track's first release:

```haskell
data TrackSnapshot = TrackSnapshot
  { tsTrack        :: Text          -- "production" | "internal"
  , tsVersionName  :: Text
  , tsVersionCode  :: Maybe Int32
  , tsStatus       :: Text          -- completed | inProgress | halted | draft
  , tsUserFraction :: Maybe Double  -- staged rollout (production)
  , tsReleaseNotes :: Maybe Text    -- releaseNotes[defaultLang]
  }
fetchTrackSnapshots :: PlayCreds -> Text -> m (Either PlayApiError [TrackSnapshot])
```

**Apple (`Versioning/Apple.hs`)** — compose existing primitives:
- production: `getAppStoreVersion` (version + `appStoreState`→status) + `getPhasedReleaseState`
  (day→%) + a localization read for `whatsNew`.
- testflight: `fetchAscVersions` (latest build version) + build `processingState` (VALID) +
  beta-build localization for "What to Test".

```haskell
data AscSnapshot = AscSnapshot { asTrack, asVersion, asStatus :: Text, asPercent :: Maybe Double, asWhatsNew :: Maybe Text }
fetchAscSnapshots :: AscCreds -> Text -> m (Either AscError [AscSnapshot])
```

Both are new reads built on existing, tested client code — no new auth.

---

## 6. Database — `store_status` cache

```sql
CREATE TABLE IF NOT EXISTS store_status (
  app_catalog_id    INT  NOT NULL REFERENCES app_catalog(id) ON DELETE CASCADE,
  platform          TEXT NOT NULL,            -- android | ios
  track             TEXT NOT NULL,            -- production | internal | testflight
  version_name      TEXT,
  version_code      INT,
  status            TEXT,                     -- live | completed | VALID | halted | in_review | …
  rollout_percent   DOUBLE PRECISION,         -- production staged-rollout % (Tier 1)
  review_status     TEXT,                     -- in_review | approved | rejected (production)
  release_notes     TEXT,                     -- "What's New" for this track's current version
  expected_version  TEXT,                     -- last SCC-shipped version, for drift ⚠
  synced_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (app_catalog_id, platform, track)
);
```

≈40 rows, upsert-on-poll (`ON CONFLICT (app_catalog_id, platform, track) DO UPDATE`). The PK
covers every access path — no extra index needed. Migration number: next free at build time.

---

## 7. API contract

| Method | Path | Perm | Returns |
|---|---|---|---|
| GET | `/mobile/store-monitor` | `AP_RELEASE_VIEW` | the whole grid + modal data (below) |
| POST | `/mobile/store-monitor/:appCatalogId/refresh` | `AP_RELEASE_VIEW` | live re-poll one app → upsert → return its fresh card |

**`GET /mobile/store-monitor` response** (one call powers everything):
```jsonc
[
  {
    "app": "Bharat Taxi", "appCatalogId": 12, "surface": "customer",
    "platforms": {
      "android": {
        "bundleId": "in.mobility.bharatTaxi",
        "production": { "version": "0.0.26", "buildCode": 59, "status": "live",
                        "rolloutPercent": 100, "reviewStatus": null,
                        "releaseNotes": "We've been tuning things up…",
                        "drift": false, "syncedAt": "…" },
        "internal":   { "version": "0.0.26", "buildCode": 59, "status": "completed",
                        "releaseNotes": "…", "syncedAt": "…" }
      },
      "ios": { "production": { … }, "testflight": { … } }   // or null = "No iOS configuration"
    }
  }
]
```

The modal reads `selectedApp.platforms[os]` — both tabs already present. Additive, under the
existing `/mobile` Servant tree; no versioning churn.

---

## 8. Backend modules

| Module | New/extend | Responsibility |
|---|---|---|
| `Versioning/Play.hs` | extend | `fetchTrackSnapshots` — per-track version/code/status/%/notes |
| `Versioning/Apple.hs` | extend | `fetchAscSnapshots` — production + testflight snapshots incl. `whatsNew` |
| `Mobile/Types/Storage.hs` | extend | `StoreStatusT` Beam table |
| `dev/migrations/.../00NN-store-status.sql` | new | the cache table |
| `Mobile/Queries/StoreStatus.hs` | new | upsert + `listStoreStatus` (joined with `app_catalog`) + action mirrors (`setProductionRolloutStatus` / `setProductionReleased` / `setProductionReviewStatus`, see §10) |
| `Mobile/StoreSync.hs` | extend | poll snapshots → upsert `store_status` (+ drift compare vs `release_tracker`) |
| `Mobile/Handlers/StoreMonitor.hs` | new | `GET /store-monitor`, `POST /refresh` |
| `Mobile/Routes.hs` | extend | mount the two endpoints |

**Drift** = `store_status.version_name` ≠ the latest COMPLETED `release_tracker.new_version`
for that `(app_group, service, env)`. Computed at read (or stamped on poll into
`expected_version`).

---

## 9. Frontend

- **`pages/mobile/StoreMonitor.tsx`** — the cards grid. `useQuery(['store-monitor'])` → one
  fetch; search box + ↻ refresh; auto-poll (e.g. 60s) like the other mobile pages. Each card
  = one app, android/ios columns, per-track cells with the lifecycle badge.
- **`components/AppTrackModal.tsx`** — opens client-side from the loaded card object. Header
  (display label + bundle id + platform), Production / Internal-Testing tabs, version + build
  code + status badge + rollout %, and the RELEASE NOTES block. **No fetch on open.**
- **`api.ts` / `types.ts`** — add `mobileApi.storeMonitor()` + `mobileApi.refreshStoreApp(id)`
  and the `StoreMonitorApp` / `TrackCell` types. Add a nav entry/route for the page.
- Gated on `AP_RELEASE_VIEW`; refresh button on `AP_RELEASE_VIEW` (read-tier action).

---

## 10. Caching & invalidation

- `store_status` **is** the cache. `synced_at` drives the freshness badge (amber if older
  than the poll interval).
- **Refresh paths:** the poller overwrites on schedule; ↻ forces a one-app live re-poll.
- **Reflect on action — mirror, don't re-poll** *(2026-06-19)*: a promote / rollout-set /
  halt / resume / release-all / `mark-approved` / `mark-rejected` / withdraw from the
  staged-rollout feature changes one app's state. Re-polling the store here is the wrong
  tool — the per-app refresh is **cooldown-gated** (within the window it just serves the
  stale cache), and forcing it past the cooldown spends a **second** Play/ASC edit right
  after the action's own edit, which is the per-app edit rate the cooldown exists to cap.
  Instead each handler **mirrors the new state it just applied straight into `store_status`**
  (production row only, no store call): the rollout `%` + `status` (`inProgress` while
  ramping/resumed, `halted` while paused, `completed`+`review_status = NULL` at 100%) and the
  review overlay (`in_review` / `approved` / `rejected`) — i.e. exactly what the next sync's
  live-status + `findActiveMobileState` overlay would compute. The FE then invalidates
  `['store-monitor']` so the grid refetches the patched cache. Phase 7's reconciler still
  corrects the row to the true live value on the next real refresh.
  Helpers: `setProductionRolloutStatus` / `setProductionReleased` / `setProductionReviewStatus`
  in `Queries/StoreStatus`; wired through `Handlers/Rollout`. Without this the monitor lagged
  the release list (which reads `release_tracker` directly) until the next poll — most visibly,
  a **halt** showed on the list but not the monitor.

---

## 11. Edge cases

1. **Missing creds** — no Play/ASC creds → show the cached row with a stale badge, never a hard error.
2. **One-platform apps** — `platforms.ios = null` → "No iOS configuration" (screenshot behavior).
3. **Debug envs** — poller skips them (no production store data); the page is release-env only.
4. **No release notes on a track** — render "—" / "No release notes", not an empty box.
5. **Provider iOS** — production may not exist until promoted (TestFlight-only); show TestFlight, and production once SCC creates it (Phase 10).
6. **Rate limits** — only the poller and the explicit ↻ hit the stores; the page never does.
7. **Drift false-positive** — a synthetic store-sync row IS the SCC record; compare against the newest non-store-sync release to avoid flagging our own ship.

---

## 12. Build order (roadmap)

> One task = one commit. `sc-build` after each Haskell change, `sc-test` after tests. No `Co-Authored-By`.

> **Status (built 2026-06-16):** all of M1–M6 landed. Notes vs the original plan:
> - `AscSnapshot` shipped as `{ascTrack, ascVersion, ascStatus, ascNotes}` (no
>   `asPercent` field); iOS production rollout % is overlaid at poll time from the
>   active `release_tracker` row instead, so the snapshot stays a pure read.
> - Lifecycle-badge derivation lives in the **frontend** (`storeBadge.ts`) — the
>   API returns the raw `TrackCell` fields (the contract has no badge field).
> - The poller covers **all** catalog apps (`listAppCatalog`), not just enabled
>   ones, so every app's live releases show. Review state + iOS phased % are
>   overlaid from the most-recent active `release_tracker` row (Play never exposes
>   review). Migration number: **0030**.

- [x] **M1 — Store reads** — `fetchTrackSnapshots` (Play) + `fetchAscSnapshots` (Apple) incl. notes + rollout %; unit-tested ([45]).
- [x] **M2 — Cache** — `0030-store-status.sql` + `StoreStatusT` + `Queries/StoreStatus` (upsert + list + drift/active-state reads).
- [x] **M3 — Poller** — `StoreSync.syncStoreStatus` writes `store_status` for all apps + drift baseline + active-state overlay.
- [x] **M4 — API** — `Handlers/StoreMonitor` (`GET /store-monitor`) + route; cards assembled from the cache.
- [x] **M5 — Frontend** — `StoreMonitor` grid + `AppTrackModal` (client-side) + api/types/route.
- [x] **M6 — Refresh** — `POST /:id/refresh` (live re-poll) + the ↻ button + freshness badge.
- [x] **M7 — Action mirror** *(2026-06-19)* — every staged-rollout action mirrors its new
  state into `store_status` (no extra store edit) so the monitor matches the release list
  immediately; FE invalidates `['store-monitor']` after each action. See §10.

---

## 13. Future scope (Tier 2 / 3 — not in this build)

**Tier 2 — store quality & history:** crash-free % / ANR (Play Vitals / Crashlytics), rating
+ # ratings with trend, policy/rejection reasons on the card, release-notes history + the AI
summary, rollout-% timeline sparkline.

**Tier 3 — proactive ops:** Slack alerts (out-of-band live change · rollout stalled · review
rejected · crash spike), stuck-rollout flag, filters (stale / drifted / rolling-out /
in-review), per-country phased rollout, internal→beta→production track funnel, daily digest.

---

## 14. Decisions locked

- **One API call** returns the dashboard **and** all modal data (incl. release notes); the modal is client-side, no fetch on open.
- **Cache-backed** via the existing `StoreSync` poller — the page is one DB read; only the poller + explicit ↻ touch the stores.
- **Tier 1 is in scope** (rollout %, review/rollout badge, drift ⚠, version gap, freshness/refresh, click-through) — cheap because the rollout/review data already flows from the staged-rollout feature.
- **Reuse existing store auth + clients** (Play JWT/OAuth, Apple ES256; `getTrackRolloutState` / `getPhasedReleaseState` / `getAscReviewState`).
- **New `store_status` cache table** keyed by `(app_catalog_id, platform, track)` — not mined from `release_tracker`, which records per-version history, not current per-track state.
