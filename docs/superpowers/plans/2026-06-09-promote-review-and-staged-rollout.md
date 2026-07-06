# Promote to Review → Staged Rollout — Implementation Plan

> **⚠️ Note (2026-06-18) — store sync is now on-demand.** Where this plan references the
> `storeSyncLoop` background poller / `store_sync_*` flags, those were **removed**: store
> sync (and the rollout reconcile it carried) now runs **on demand** via
> `refreshStoreStatusOne`, bounded by `store_refresh_cooldown_seconds`. The staged-rollout
> logic itself is unchanged. Current behaviour: `CLAUDE.md` § "Mobile store sync
> (on-demand)" and `docs/scc-deployment.md` §7.

> **Status:** Design locked, ready to build.
> **Date:** 2026-06-09 · **Branch base:** `mobile-release-features`
> **Supersedes:** the earlier `2026-05-20-staged-rollout.md` plan (since **removed** — it was
> stale: a removed `MobileDestination` ADT, Play write-functions that didn't exist, and the
> wrong migration number). This document is the as-built record.

---

## 1. What we are building (in plain words)

Today, when we create a **production mobile release**, the build is made by GitHub
Actions and uploaded to the stores — and then the SCC release is just marked "Completed."
Nothing else happens automatically, and we have no control over the store side from SCC.

We want to add the **last part of the release lifecycle**, controlled from SCC:

1. **Promote to review** — send the built app to Google Play / App Store for approval,
   filling in the **release notes** from SCC (reviewer info / demo account are already set on
   the store and carried forward — v1 doesn't touch them; see §4).
2. **Wait for approval** — track whether the store approved or rejected it.
3. **Do NOT release automatically** — after approval, the app should sit and wait.
4. **Roll out with a button** — an operator clicks "Roll out" and chooses a percentage
   (staged rollout), then bumps it up over time until 100%.

So the operator drives the whole thing from SCC instead of logging into the Play Console
or App Store Connect.

---

## 2. How releases work today (the starting point)

The SCC mobile workflow runs these steps and then stops:

```
Create → Approve → Dispatch → [GitHub Actions builds + uploads] → Tag pushed → Completed
```

The actual build and upload happen in **GitHub Actions + fastlane**, which lives in a
**different repo** (`ny-react-native`), not in SCC. We read those fastlane scripts to find
out exactly where the app binary ends up. This is the single most important fact for the
whole feature, so here it is:

| App type | What fastlane does | Where the binary ends up |
|---|---|---|
| **Consumer Android** | `supply(track: 'internal')` | Google Play **Internal** track (production track is empty) |
| **Provider Android** | uploads with `track = 'internal'` | Google Play **Internal** track |
| **Consumer iOS** | `upload_to_app_store` (does **not** submit) | App Store version in **"Prepare for Submission"** (uploaded, not sent) |
| **Provider iOS** | `upload_to_testflight()` only | **TestFlight only — no App Store version exists** |

**Why this is great news:** SCC can fully own the "promote → review → roll out" lifecycle
**without changing fastlane** (except the provider-iOS gap, see §11). The binary is already
staged; SCC just has to move it forward.

Also important: fastlane **skips all the metadata** (`skip_upload_metadata`,
`skip_upload_changelogs`, `skip_metadata`, `skip_screenshots`). That means the release
notes and review info are **not filled in yet** — SCC fills them. That's exactly the
control we want.

---

## 3. The new end-to-end flow

```
Build done (today's "Tag pushed")
        │
        ▼
  ┌──────────────────────────────────────────────┐
  │  PROMOTE TO REVIEW   (operator clicks a button) │
  │  - fill release notes (from changelog)          │
  │  - fill reviewer info / demo account (iOS)      │
  │  - submit to the store for approval             │
  └──────────────────────────────────────────────┘
        │
        ▼
  ┌──────────────────────────────────────────────┐
  │  IN REVIEW   (SCC polls the store)              │
  │  iOS:  can see "approved / rejected" clearly    │
  │  Android: review is opaque (see §5)             │
  └──────────────────────────────────────────────┘
        │
        ▼
  ┌──────────────────────────────────────────────┐
  │  APPROVED — HELD   (nothing live yet)           │
  │  iOS:  PENDING_DEVELOPER_RELEASE                │
  │  Android: see §5 for what "held" means here     │
  └──────────────────────────────────────────────┘
        │  operator clicks "Roll out" and picks %
        ▼
  ┌──────────────────────────────────────────────┐
  │  ROLLING OUT   (staged %)                       │
  │  Android: 1% → 10% → 50% → 100% (custom %)      │
  │  iOS:  Apple's fixed 7-day phased schedule      │
  │        (1,2,5,10,20,50,100) — pause/resume/all  │
  └──────────────────────────────────────────────┘
        │
        ▼
     COMPLETED (100%)
```

**Two rules we locked in:**
- **Promote is operator-gated** — a human clicks "Promote to Review." No auto-submit.
- **After approval we never auto-release** — a human clicks "Roll out."

---

## 4. The data we fill when submitting (your first question)

When you submit through the Play Console / App Store Connect website you fill a form — but
the stores **persist most of those fields across versions**. App Store Connect copies the
App Review Information (reviewer contact, demo account, notes) and the export-compliance
answer **forward onto every new version automatically**. Our apps are **already live and
already passing review**, so those values are **already set in the store**.

**So v1 owns exactly one field: the release notes ("What's New").** Everything else defers
to whatever the store already has. SCC pushes only:

| Data | Store field | Where SCC gets it |
|---|---|---|
| Release notes / "What's New" | Play `releaseNotes`; iOS `whatsNew` (per listed language) | **The release's changelog** — the `summary_short` synopsis; no per-app config |
| Release type (manual) | iOS `appStoreVersions.releaseType` | Always `MANUAL` (so it won't auto-release) |
| Initial rollout % | Play `userFraction` | Default **≈0%** (`1e-9`, config `android_review_rollout_fraction`) so approval exposes no users — see §5 |

**NOT pushed by v1** (already on the store version, carried forward): reviewer contact, demo
account, reviewer notes, export compliance. SCC leaves them untouched.

**Why this is safe:** an app that passes review today already has a working demo account,
reviewer contact, and compliance answer on its live version, and ASC carries them forward.
v1 never authors them — it only re-authors **What's New**, which changes every release.

**When v1 is NOT enough** (→ deferred to Phase 2, see §6a): a brand-new app with no prior
version to carry from; or the day you must *rotate* demo-account credentials / change reviewer
contact **from SCC** rather than the store UI. That is when the per-app config table earns its
place — not before.

---

## 4a. Prefill / never-clobber (deferred to Phase 2 with the config table)

Because v1 pushes **only What's New** and defers every sticky field to the store, there is
**nothing to clobber** — SCC never writes reviewer contact, demo account, notes, or
compliance, so the "read-first, 3-way-merge, conflict-preview" machinery is **not needed in
v1**. The full data-ownership model (store = source of truth for sticky fields,
`config_authoritative` override, the 3-way-merge promote-form preview) lands **with the
config table in Phase 2** — see §6a.

Two rules v1 still keeps:
- **What's New is always overwritten** with the new changelog (we don't want the previous
  version's carried-forward notes).
- **Export compliance**: if Info.plist already declares `ITSAppUsesNonExemptEncryption`, do
  **not** set it via API (ASC rejects the duplicate). v1 sets nothing here, so this holds by
  construction — just confirm the flag is present in Info.plist (see §14).

---

## 5. iOS vs Android — the important difference (your second question)

You asked for: *"after approval, don't auto-release; give a roll-out button with stagger %
like Play Store has."*

**iOS does this perfectly:**
- We submit with **release type = MANUAL**.
- After Apple approves, the version becomes **`PENDING_DEVELOPER_RELEASE`** — approved but
  nothing is live.
- The operator clicks **"Release"** → SCC calls `POST appStoreVersionReleaseRequests`.
- If phased release is on, Apple then ramps over 7 days (1,2,5,10,20,50,100%). SCC can
  pause, resume, or "release to everyone." Apple controls the exact %, not us.

**Android — we replicate the team's proven manual approach: submit at ~0%.**
- Google Play's **staged rollout IS the roll-out button you want** — we can set any custom
  percentage and bump it whenever we like. ✅ Fully supported.
- For the "approved-but-held" part, we do exactly what the team already does by hand:
  **submit the production release at an effectively-zero rollout** — `0.0000001%`, which is
  `userFraction = 0.000000001` (1e-9), i.e. one in a billion users = nobody.
  - Promote: create the production release `{status:"inProgress", userFraction:1e-9,
    releaseNotes:<changelog>}` → commit → review.
  - After Google approves, the release is technically "live" but serves ~0%, so functionally
    it is **held** — just like iOS `PENDING_DEVELOPER_RELEASE`. The previous version keeps
    serving everyone.
  - The **roll-out button** then bumps `userFraction` to real values (1% → 10% → 50% →
    100%) when the operator is ready.
- This gives Android the same two-step gate as iOS without managed publishing or untested
  tricks: **promote (≈0%, to review) → approved (still ≈0%, nobody) → operator rolls out.**
- Make the tiny value a **config flag** `android_review_rollout_fraction` (default
  `0.000000001`) so ops can tune it without a redeploy.
- **Review is still opaque on Android** — there is no API field that says "approved" or
  "rejected" the way iOS has `appStoreState`. So the approve/reject **decision** is confirmed
  by the operator (Console/email), not auto-detected. See §12a for rejection handling.
  *(Update 2026-06-16: the decision stays operator-marked, but SCC now **detects out-of-band
  submissions and rollouts** — a Console-started review surfaces as a "Pending review" row, and
  a Console-set rollout % is adopted into SCC's lifecycle. See "Post-roadmap extensions (built
  2026-06-16)".)*

> ⚠️ **Verify in dev:** the docs say the *Play Console UI* range is 1%–100%; sub-1%
> fractions like 1e-9 work via the **raw Android Publisher API** (which is what SCC calls),
> and the team already uses them — but confirm the API accepts the exact value, since the
> team may currently set it via the Console UI rather than the API. If rejected, lower the
> config to the smallest accepted value.

**Plain summary:** both platforms get a true "approved, nothing live until you act" gate —
iOS via `releaseType:MANUAL`, Android via submit-at-~0% staged rollout. The roll-out button
controls exposure on both.

---

## 6. Database changes (v1)

**One migration in v1.** The repo is at `0025`, so this is **0026**. The per-app config
table (`0027`) is **deferred to Phase 2** — see §6a; v1 needs no per-app config because it
only pushes What's New and defers everything else to the store.

### `0026-staged-rollout.sql` — track review + rollout state on each release
```sql
ALTER TABLE release_tracker
  ADD COLUMN IF NOT EXISTS review_status        TEXT,        -- in_review | approved | rejected (iOS); submitted | live (Android)
  ADD COLUMN IF NOT EXISTS review_submitted_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS review_decided_at    TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS review_reject_reason TEXT,
  ADD COLUMN IF NOT EXISTS rollout_status       TEXT,        -- rolling_out | halted | completed
  ADD COLUMN IF NOT EXISTS rollout_percent      NUMERIC,     -- current live % (0.1–100)
  ADD COLUMN IF NOT EXISTS rollout_history      JSONB,       -- [{percent, started_at, ended_at, notes, actor}]
  ADD COLUMN IF NOT EXISTS asc_version_id       TEXT,        -- iOS: App Store version id (cache it)
  ADD COLUMN IF NOT EXISTS asc_phased_id        TEXT;        -- iOS: phased-release id (for pause/resume)

CREATE INDEX IF NOT EXISTS idx_rt_review_status  ON release_tracker(review_status)  WHERE review_status  IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rt_rollout_status ON release_tracker(rollout_status) WHERE rollout_status IS NOT NULL;
```

The exact payload we send to the store on each attempt is also saved as a `SUBMISSION`
event in `release_events` (same pattern we already use for snapshots) — so we have an audit
trail.

---

## 6a. Per-app store config — DEFERRED to Phase 2

Not built in v1 (see §4 / §4a). Add this **only** when a real need appears: onboarding a
brand-new app, or rotating demo-account creds / overriding reviewer contact from SCC instead
of the store UI. When that day comes, add a **slim** table — likely just
`demo_account_secret_ref`, `config_authoritative`, plus whatever field you're actually
overriding, **not** the full set below — and restore the §4a 3-way-merge / never-clobber
model at the same time. The full shape it could take (`0027`, or the next free number then):

```sql
CREATE TABLE IF NOT EXISTS app_store_submission_config (
  app_catalog_id            INT PRIMARY KEY REFERENCES app_catalog(id),
  review_contact_first_name TEXT,
  review_contact_last_name  TEXT,
  review_contact_email      TEXT,
  review_contact_phone      TEXT,
  demo_account_required     BOOLEAN NOT NULL DEFAULT FALSE,
  demo_account_name         TEXT,
  demo_account_secret_ref   TEXT,      -- name of the secret, NOT the password itself
  reviewer_notes            TEXT,
  uses_non_exempt_encryption BOOLEAN,
  default_locale            TEXT NOT NULL DEFAULT 'en-US',
  extra_locales             JSONB,     -- optional per-language release notes overrides
  config_authoritative      BOOLEAN NOT NULL DEFAULT FALSE,  -- FALSE: fill-gaps + preview conflicts; TRUE: SCC overwrites the store
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Field semantics:** a `NULL` column = *"SCC does not manage this field — defer to whatever
the store has."* `config_authoritative = FALSE` (default) = SCC only fills missing fields and
surfaces conflicts for the operator to confirm; `TRUE` = SCC overwrites the store on submit.

**Security note:** the demo-account **password** must NOT be stored in plain text — store a
**reference to a secret** (`demo_account_secret_ref`, like the `SC_*` store keys) and resolve
it at submit time.

---

## 7. New API endpoints (what SCC exposes)

| Method | Path | Permission | What it does |
|---|---|---|---|
| GET  | `/releases/:id/promote-form` | `AP_RELEASE_VIEW` | v1: returns the changelog-derived release notes (editable) + current store review state. (The 3-way-merge preview returns with the config table in Phase 2 — §6a) |
| POST | `/releases/:id/promote` | `AP_RELEASE_PROMOTE` | Fills metadata and submits the app for review |
| GET  | `/releases/:id/rollout` | `AP_RELEASE_VIEW` | Returns current review + rollout state |
| POST | `/releases/:id/release` | `AP_RELEASE_ROLLOUT` | **iOS only** — releases an approved (held) version |
| POST | `/releases/:id/rollout/set` | `AP_RELEASE_ROLLOUT` | **Android only** — set rollout % (0.1–100) |
| POST | `/releases/:id/rollout/halt` | `AP_RELEASE_ROLLOUT` | Pause the rollout |
| POST | `/releases/:id/rollout/resume` | `AP_RELEASE_ROLLOUT` | Resume a paused rollout |
| POST | `/releases/:id/rollout/release-all` | `AP_RELEASE_ROLLOUT` | Jump to 100% (both platforms) |
| POST | `/releases/:id/review/mark-rejected` | `AP_RELEASE_PROMOTE` | **Android** — operator records a store rejection + reason (review is opaque, can't auto-detect) |
| POST | `/releases/:id/review/mark-approved` | `AP_RELEASE_PROMOTE` | **Android** — operator confirms Google approved it. *(2026-06-16: now **required** before a rollout — the implicit "first rollout implies approval" shortcut was removed.)* |
| POST | `/mobile/bulk/promote` | `AP_RELEASE_PROMOTE` | *(2026-06-18)* Promote MANY apps in one click — a thin loop over `promoteH`, per-app `try`-isolated (partial failures reported per app), run sequentially to respect Play's one-edit-per-app quota |
| POST | `/mobile/bulk/rollout` | `AP_RELEASE_ROLLOUT` | *(2026-06-18)* Set the Android rollout % for many apps at once (same or per-app %) — a thin loop over `rolloutSetH`, same isolation/sequencing |
| ~~PUT~~ | ~~`/apps/:id/store-config`~~ | `AP_MOBILE_APP_MANAGE` | **Deferred to Phase 2** (§6a) — set per-app reviewer info / demo account |

Two **new permissions** to add to the `AutopilotPermission` ADT:
`AP_RELEASE_PROMOTE` and `AP_RELEASE_ROLLOUT`.

Three **server-config flags**: `android_review_rollout_fraction` (default `0.000000001` =
0.0000001%, the effectively-zero review rollout), `review_poll_timeout_days` (default `7`),
and `review_poll_interval_sec` (default `1200` = **20 min** — how often the bounded
review-poll stage actually hits the store; the runner ticks ~20s but the stage self-throttles
to this, since review runs for hours and ASC rate-limits ~3600 req/hr).

Example request bodies:
```jsonc
// POST /promote  (Android)  — submit at effectively-zero rollout so approval exposes no users
{ "releaseNotes": [{ "language": "en-US", "text": "…" }],
  "initialRolloutPercent": 0.0000001 }   // optional; omitted → android_review_rollout_fraction

// POST /promote  (iOS)  — v1 sends only What's New + release type; reviewer info / demo defer to the store
{ "whatsNew": [{ "locale": "en-US", "text": "…" }],
  "releaseType": "MANUAL",
  "enablePhasedRelease": true }
```

---

## 8. Store APIs we call (the external contracts)

We already have working **authentication** for both stores (don't rebuild it):
- **Play:** service-account JSON → JWT → OAuth token → Android Publisher v3
  (`Versioning/Play.hs` — has `createEdit`, `fetchTrack`).
- **Apple:** `.p8` key → ES256 JWT used directly as the token → App Store Connect v1
  (`Versioning/Apple.hs` — has `mintAscToken`, app + build lookup).

New calls to add:

**Google Play (Android Publisher v3):**
- `POST /edits` *(have it)*
- `PUT /edits/{id}/tracks/production` — set the release `{versionCodes, status, userFraction, releaseNotes}` *(new)*
- `POST /edits/{id}:commit` — sends it to review *(new; do NOT pass `changesNotSentForReview` — that flag holds it back from review, the opposite of what we want)*
- `GET /edits/{id}/tracks/production` — read current status / % *(reuse the read)*
- Service account needs the **Release Manager** role in Play Console.

**App Store Connect (v1):**
- `GET /builds/{id}` — check `processingState == VALID` before submitting *(new)*
- `GET /apps/{appId}/appStoreVersions?filter[versionString]=X` — find version + read `appStoreState` *(new)*
- `PATCH /appStoreVersions/{id}` — set `releaseType: MANUAL`, copyright *(new)*
- `PATCH /appStoreVersionLocalizations/{locId}` — set `whatsNew` for each language *(new)*
- ~~upsert `appStoreReviewDetails`~~ — reviewer contact + demo account + notes — **deferred to Phase 2** (§6a); v1 leaves these to the store's carried-forward values
- `POST /reviewSubmissions` (+ `reviewSubmissionItems` + `PATCH {submitted:true}`) — submit *(new; this is the modern endpoint — the old plan's `appStoreVersionSubmissions` is deprecated)*
- `POST /appStoreVersionPhasedReleases` — create phased release *(new)*; `PATCH …/{id}` to PAUSE / ACTIVE / COMPLETE
- `POST /appStoreVersionReleaseRequests` — **the "Release" button** for an approved-held version *(new)*
- API key needs **App Manager / Admin** role.

---

## 9. The state machine (statuses on a release)

We add new fine-grained statuses to `MobileBuildWFStatus`:

```
… MBTagPushed            (build done — today's end point)
   │  operator clicks "Promote to Review"
   ▼
MBSubmittingForReview     (filling data + submitting)
   ▼
MBInReview                (waiting on the store)
   ├── iOS approved → MBReviewApproved   (held; PENDING_DEVELOPER_RELEASE)
   │       │  operator clicks "Release"
   │       ▼
   │   MBRollingOut → MBCompleted
   │
   ├── Android approved → (canary) auto-live at 1% → MBRollingOut → MBCompleted
   │                    → (halted, if supported) MBReviewApproved → operator sets % → MBRollingOut
   │
   └── rejected → MBReviewRejected   (terminal; shows as ABORTED with the reason)
```

Rules:
- `MBReviewApproved` and `MBRollingOut` are **not** terminal (the release is still active).
- `MBReviewRejected` **is** terminal and maps to user-facing `ABORTED`.
- The review poll must be **bounded** — reuse the existing `tagConfirmTimedOut` timeout
  pattern, with a **generous 7-day** soft timeout that surfaces "review is taking long"
  rather than failing the release.

---

## 10. Backend modules to build / extend

| Module | New or extend | Responsibility |
|---|---|---|
| `Versioning/Play.hs` | extend | Promote internal→production, set/halt/resume/complete rollout, read track state |
| `Versioning/Apple.hs` | extend | Fill metadata, submit for review, poll `appStoreState`, phased-release control, manual release |
| `Mobile/Types.hs` | extend | New workflow statuses + `ReviewStatus` / `RolloutStatus` / `RolloutStage` types |
| `Mobile/Workflow.hs` | extend | New stages: submit-for-review, poll-review (bounded) |
| `Mobile/Handlers/Rollout.hs` | **new** | Promote, release, set %, halt, resume, release-all, get detail. *(2026-06-18)* + bulk promote/rollout (thin loops over the single-item handlers). *(2026-06-18)* Observed-rollout **adoption**: a store-sync snapshot SCC only saw rolling out in the Console (`STORE_SYNC` + `MBCompleted` + `rollout_status` rolling/halted) is taken into SCC's lifecycle by `/rollout/set` without the approval gate (`isObservedRollout`). *(2026-06-19)* Every action **mirrors** its new production state into `store_status` so the App Monitor matches the release list immediately — see the monitoring plan §10 |
| ~~`Mobile/Handlers/AppCatalog.hs`~~ | extend | Store-config endpoint (reviewer info) — **Phase 2** (§6a), not v1 |
| `Mobile/Queries/Tracker.hs` | extend | Update review/rollout columns, append rollout history |
| `Mobile/StoreSync.hs` | extend | Background reconciler: keep SCC in sync if someone changes things in the Console |
| `Mobile/Routes.hs` | extend | Mount the new endpoints |
| `Types/Permission.hs` | extend | Add `AP_RELEASE_PROMOTE`, `AP_RELEASE_ROLLOUT` |

---

## 11. Frontend changes

On the **release detail page** (`ReleaseSummary.tsx`):
- A **"Promote to Review"** button — shown once the build completes (`MBTagPushed`) on
  **release** builds only (debug builds skip review). It opens a promote form whose core is a
  **release-notes textarea pre-filled with the generated `summary_short`** (the review-ready
  prose from the changelog) — the operator **edits rather than writes from scratch**, and can
  leave it as-is.
  - **Per release row** (per app + platform), **not** per group: each app goes to its own
    store with its own notes (§12.13). A mixed Android + iOS group shows a promote button per row.
  - **iOS:** the same notes apply to **every listed locale** (`whatsNew`); the form **locks**
    once submitted (Apple won't let notes change mid-review, §12.7). Release type is Manual;
    phased release is opt-in.
  - **Android:** the notes become the production release's `releaseNotes`, submitted at the
    effectively-zero review % (config-driven).
  - Reviewer info / demo account are **not** in the v1 form — they defer to the store
    (Phase 2 adds them, §6a). Button gated on `AP_RELEASE_PROMOTE`.
- A **"Store Review"** panel showing: submitted / in review / approved / rejected (+ reason).
  For Android, also show **"Mark Approved"** / **"Mark Rejected"** buttons (review is opaque).
- A **"Release"** button (iOS only) once the state is approved-held.
- A **"Rollout"** panel: Android shows a % input + bump/halt/resume/release-all; iOS shows
  the phased schedule + pause/resume/release-all.

On the **app admin page**: a form to set the per-app reviewer info / demo account once — **deferred to Phase 2** (§6a).

On the **releases list**: a small badge ("In review", "↗ 5%", "Halted").

On the **App Release Monitor page** *(2026-06-19)* — a **Bulk actions panel** (`MobileBulkPanel.tsx`)
above the cards: select many apps and promote / set rollout % in one click (calls the bulk
endpoints). Two clearly-labelled sections (Promote = internal/TestFlight; Rolling out = Android %),
grouped by app, two-per-row and responsive (single column < `xl`). Each row's right side shows the
**same status badge as the list/detail** — driven by the shared `mobileDisplayStatus` projection, so
"Halted · X%" / "Rolling out · X%" / "Approved · held" read identically everywhere — plus a halt-aware
(amber) progress bar. Partial failures are surfaced per app, mapped failed release-id → app label.
After a bulk action it invalidates `['releases']`, `['release']`, `['mobile-rollout']` **and**
`['store-monitor']`. *(Bulk promote is currently feature-flagged off in the UI; bulk rollout is live.)*

> **Badge consistency:** the promote→review→rollout→completed lifecycle is projected to a UI
> stage/badge in one place — `components/mobileStage.ts` (`lifecycleFromRelease` / `stageOf` /
> `mobileDisplayStatus`). The list badge, the detail panel, and the bulk panel all read it, so they
> can't drift. A row's authoritative `rollout_status` / `rollout_percent` ride in `release_context`
> (injected by the tracker serializer) with the store-sync metadata as fallback.

---

## 12. Edge cases to handle

1. **iOS many languages** — `whatsNew` must be set for *every* language the app lists, or
   some regions show empty/old notes. Apply the changelog to all languages.
2. **iOS compliance double-set** — if Info.plist already declares
   `ITSAppUsesNonExemptEncryption`, don't set it via API (ASC rejects the duplicate). Read
   the build first; set via API only if missing. If neither has it, submission is blocked.
2b. **Store already has the field (prefill)** — v1 never writes sticky fields (review
   contact / demo account / notes), so there's nothing to clobber. The read-first /
   fill-gaps / preview-conflicts handling arrives with the config table in **Phase 2** (§6a / §4a).
2c. **Stale carried-forward review data** — ASC copies old contact/demo forward; in v1, if it's
   out of date the operator fixes it **in the store UI** (SCC has no override yet — that's Phase 2).
3. **iOS demo account required but missing** — Apple rejects. v1 relies on the store's
   carried-forward demo account; before submitting, confirm one exists on the version — if not,
   block with a clear message and have ops set it in ASC (SCC-managed demo creds are Phase 2).
4. **Empty release notes** — required for updates. Default from the changelog; block empty.
5. **Android note language** must match a language already on the store listing.
6. **Approved-held but never released (iOS)** — show a reminder banner; never auto-release.
7. **Can't edit notes after submitting (iOS)** — lock the form once it's in review.
8. **Re-submit after rejection** — reviewer info persists; only notes change.
9. **Android review is opaque** — never show a fake "Approved" for Android from polling.
   See §12a for the full rejection/approval handling.
10. **Halt/resume race** — always read the live store state before acting; don't trust the
    cached %.
11. **% bounds** — Play rejects 0 and ≥1.0; for 100% use `status: completed` (drop the
    fraction), don't send 1.0.
12. **Store-sync rows / debug builds** — skip them; they have no build to promote.
13. **Batch releases** — promote/roll out is **per release row**, not per group; don't let
    one button move an entire mixed Android+iOS group.
14. **Revert during rollout** — a `rolling_out` release is now non-terminal; update the
    revert guards and the in-flight-revert unique index to account for it.
15. **Demo password secret missing** — N/A in v1 (no SCC-stored `secret_ref`; demo creds live in the store). Re-applies in Phase 2: fail clearly ("demo credentials not configured").

---

## 12a. What if the Android app is NOT approved?

Because we submit at **effectively 0%** (§5), a rejection has **near-zero impact** — no
users got the new version, and the previous version keeps serving everyone. An Android
rejection is low-stakes: fix and resubmit.

**What actually happens on Google's side:**
- The update is simply **not published**; the prior version stays live.
- Google notifies via **email + the Play Console** (Policy status / Publishing overview /
  app status = *Rejected*).
- The Android Publisher **API does not expose a "rejected" — or even "approved" — signal.**
  Review/policy status is only in the Console UI. So we cannot auto-detect the outcome the
  way iOS's `appStoreState` allows.
- A pending/rejected change can **block the next submission** until cleared — the resubmit
  flow must discard the stuck edit first.

**How SCC handles it:**

| Situation | SCC behavior |
|---|---|
| After promote | `review_status = 'submitted'`, status shown as **"Submitted — review is opaque on Android."** Never fake an "Approved" badge. |
| Approval (opaque) | Operator confirms live via Console/email → clicks **"Mark Approved"**. *(2026-06-16: a rollout now **requires** an explicit Mark Approved first — the old "first rollout implies approval" shortcut was removed, since the API can't confirm Google actually approved; and the approval now persists across reload instead of being re-inferred back to "in review".)* |
| Rejection | Operator clicks **"Mark Review Rejected"** + pastes the reason → `MBReviewRejected` (terminal → `ABORTED`), reason saved, audit-logged. |
| Taking too long | After `review_poll_timeout_days` (default 7) still un-rolled-out → surface **"Review pending too long — check Play Console."** A nudge, not a failure. |
| Resubmit | Fix (new build/commit) → new release → promote again. Discard/clear any stuck pending change first, or the new edit can be blocked. |

**Best-effort hint — BUILT (2026-06-16):** SCC reads the production track and surfaces an
out-of-band submission as a "Pending review" `EXTERNAL_REVIEW` row (`inProgress` at the
near-zero review fraction, versionCode above the live `completed` one), and **adopts** a
Console-started rollout (fraction at/above the 1% rollout floor) into its lifecycle
(`pendingPublishRelease` / `detectConsoleRollout`). Still a best-effort *hint* — the API
can't cleanly tell "in review" from "approved & held", so the approve/reject decision stays
operator-marked. See "Post-roadmap extensions (built 2026-06-16)".

**iOS contrast:** iOS gives a clean `REJECTED` / `METADATA_REJECTED` via `appStoreState`, so
iOS rejection is **auto-detected**; only Android needs the manual mark-rejected path above.

---

## 13. Roadmap (build in this order)

> One task = one commit. Run `sc-build` after each Haskell change, `sc-test` after tests.
> Don't trust "it compiled" — verify against the running server (ghcid does NOT hot-reload
> library code). Don't add new dependencies. No `Co-Authored-By` in commits.

- [x] **Phase 1 — Schema + types** (`0027` migration — Beam columns, new statuses + types; per-app config table deferred, see §6a)
- [x] **Phase 2 — Play client** (promote internal→production, set/halt/resume/complete %, read state) + unit tests on % bounds and track parsing
- [x] **Phase 3 — Apple client** (fill metadata, submit via `reviewSubmissions`, poll `appStoreState`, phased-release control, manual release, `processingState` gate)
- [ ] ~~**Phase 4 — Per-app store config**~~ — **DEFERRED** to a later Phase 2 (§6a); not part of the notes-only v1. v1 goes straight from the Apple client (Phase 3) to workflow stages (Phase 5).
- [x] **Phase 5 — Workflow stages** (operator-gated submit; bounded review poll)
- [x] **Phase 6 — Endpoints** (promote-form, promote, rollout detail, release, rollout set/halt/resume/release-all, review mark-approved/rejected) + `AP_RELEASE_PROMOTE` / `AP_RELEASE_ROLLOUT` permissions. All gated on `mobile_staged_rollout_enabled`; `Mobile/Handlers/Rollout.hs`. `GET /rollout` returns cached columns (live store reconcile is Phase 7); promote-form pre-fills the stored changelog (FE swaps in `summary_short`).
- [x] **Phase 7 — Background reconciler** (extend `StoreSync` for active rollouts) — `reconcileActiveRollouts` runs in the store-sync loop (gated on `mobile_staged_rollout_enabled`): mirrors the live Play `userFraction` / Apple phased-ramp % into the cached columns, syncs external halt/resume, and completes a release at 100% (→ `MBCompleted`, runner finalizes). Reviews are not reconciled (iOS = Phase-5 poll, Android = operator marks). Phase-6 refinement: non-phased iOS `/release` now completes immediately instead of lingering in `rolling_out`.
- [x] **Phase 8 — Frontend** — `MobileRolloutPanel.tsx` on the release detail page (mounted beside `AiReleasePanel`, release/non-debug only): full lifecycle UI — Promote-to-Review (inline notes form + iOS phased opt-in), Store Review panel (iOS auto / Android mark-approved-rejected), iOS Release button, Android % set + halt/resume + release-all, iOS phased pause/resume/release-all. Self-hides when staged rollout is off (`GET /rollout` 400s). Buttons gated on `RELEASE_PROMOTE` / `RELEASE_ROLLOUT`. **Done (2026-06-16):** the releases-**list** status badge — `mb_wf_status` is injected into the list serialization (`fromRow` → `release_context`), and `ReleaseStatusBadge` / `mobileDisplayStatus` derive the lifecycle stage ("Ready to promote" / "In review" / "Approved · held" / "Rolling out · N%" / "Released · 100%") for INPROGRESS mobile rows. The iOS Release button also now states **phased (7-day) vs release-to-all**.
- [x] **Phase 9 — Tests + docs** — extracted the reconcile decision into pure classifiers (`androidReconcileAction` / `iosPhasedReconcileAction`) + test `[35]`; extended `[18]` to assert the full promote→review→rollout transition path + terminal `MBReviewRejected`. (True live-store E2E isn't CI-runnable; the store calls stay covered by the typed clients + these pure-logic tests.) Docs: `DATABASE.md` → "Staged-rollout columns"; `MOBILE_RELEASE_FUTURE_SCOPE.md` → moved staged rollout to **Shipped** with the open fast-follows listed.
- [x] **Phase 10 — Provider-iOS App Store path** — chose §14 option 1 (no fastlane change): the iOS submit path is now **find-or-create** (`ensureAppStoreVersion` in `Versioning/Apple.hs`). Consumer iOS already has the version (fastlane `upload_to_app_store`) → plain lookup; provider iOS (TestFlight-only) → SCC creates the `appStoreVersions` row, attaches the latest TestFlight build (`getLatestBuildId` → `createAppStoreVersion` → `attachBuildToVersion`), then submits. Transparent — no promote-handler or UI change; provider iOS works through the same `/promote` endpoint.

Phases 2 and 3 are independent and can be done in parallel.

**Post-roadmap extensions (built 2026-06-12):**
- **Store-track visibility + Option A snapshot promote** — the promote flow now also accepts a
  store-sync **internal/TestFlight snapshot** (not just SCC releases held at tag-push); promoting
  one flips the row `COMPLETED → INPROGRESS` so the runner/reconciler adopt it. Plus a
  track-aware iOS version bump and track badges across the UI. Full record:
  `2026-05-18-mobile-releases-post-mvp.md` → "Store-Track Visibility + Snapshot Promote".
- The four staged-rollout configs were added to the **Mobile** config tab
  (`server-config-filter.ts → MOBILE_SERVER_CONFIG_NAMES`).

**Post-roadmap extensions (built 2026-06-16):**
- **Out-of-band review/release detection (both platforms)** — store sync now surfaces and
  adopts store activity done *outside* SCC, so SCC's view stops lagging the store:
  - *iOS (authoritative):* `getInFlightReview` reads `appStoreState` and records a version
    submitted from App Store Connect as an `EXTERNAL_REVIEW` row (in review → approved →
    rejected, tracked). `READY_FOR_SALE` is split out as a distinct `AscLive` (was conflated
    with `PENDING_DEVELOPER_RELEASE` — the root of "released shows as approved"), and
    `detectIosRelease` adopts an ASC-released version into the rollout lifecycle (phased →
    `rolling_out @ ramp%`, else `completed`), backfilling `asc_phased_id` so the Phase-7
    reconciler tracks the ramp.
  - *Android (inferred):* `pendingPublishRelease` infers a pending submission from the
    production track (an `inProgress` release at the near-zero review fraction with a
    versionCode above the live `completed` one) and surfaces it as a "Pending review"
    `EXTERNAL_REVIEW` row; `detectConsoleRollout` adopts a Console-started rollout (fraction ≥
    the 1% floor) into SCC's lifecycle. The approve/reject *decision* stays operator-marked
    (the API can't report it). `Queries/Tracker.hs → findMobileAwaitingRollout`; `StoreSync.hs
    → detectConsoleRollouts` / `detectIosReleases` / `adoptExternalRollout`; migration `0028`
    (`EXTERNAL_REVIEW` dedup index).
- **No duplicate rows** — `sccActiveReleaseExistsForVersion` now counts a *promoted* store-sync
  row (`INPROGRESS` + `mode=STORE_SYNC`) as SCC-owned, so an SCC submission no longer spawns a
  duplicate `EXTERNAL_REVIEW` row; and the releases list hides a redundant internal/TestFlight
  snapshot when an `EXTERNAL_REVIEW` row already represents the same build (`keepSnapshot`).
- **Android mark-approved hardening** — the inferred-review reconcile no longer downgrades an
  operator's `approved`/`rejected` back to `in_review` (the approval persists across reload),
  and `ensureAndroidRollable` requires an explicit Mark Approved before a rollout (the implicit
  "first rollout implies approval" shortcut was removed).
- **Phased-vs-all clarity** — the iOS Release button states whether it does a **7-day phased
  release** or **release to all users**, driven by `rdPhasedId`; `rolloutDetailH` live-reads the
  phased id when `asc_phased_id` is null (e.g. an externally-configured phased release) so the
  label matches App Store Connect and what `/release` will actually do.
- **UI** — the version shows the **build number** (`3.3.17 +460`) everywhere it renders
  (`versionWithBuild`); the releases list's **mobile status filter** uses lifecycle buckets
  (Building / In review / Approved · held / Rolling out / Rejected / Completed / Aborted /
  Reverted) instead of backend raw statuses, and "Groups" reads "Apps".
- Tests `[40]`–`[44]` cover the pure decisions (external-review reconcile, pending-publish
  pick, list dedup, console-rollout adoption, iOS-release adoption).

**Post-roadmap extensions (built 2026-06-18 / 19):**
- **Bulk promote / rollout** — one operator action over many apps. `POST /mobile/bulk/promote`
  and `/mobile/bulk/rollout` are **thin loops** over the single-item `promoteH` / `rolloutSetH`
  (every state guard, store call, audit event and RBAC check reused verbatim, so the bulk path
  can't drift). Each item is `try`-isolated → a partial failure is recorded per app and the
  batch continues; items run **sequentially** to respect Play's one-edit-per-app quota and reuse
  the cached ASC token. UI: `MobileBulkPanel.tsx` on the App Release Monitor page (§11). Bulk
  promote is feature-flagged off in the UI for now; bulk rollout is live.
- **Observed-rollout adoption from `/rollout/set`** — a store-sync snapshot SCC only *saw*
  rolling out in the Play Console (`mode=STORE_SYNC` + `MBCompleted` + `rollout_status`
  rolling/halted) can be **adopted** by `/rollout/set` — flips `INPROGRESS` + `MBRollingOut` so
  the Phase-7 reconciler tracks it — *without* the `ensureAndroidRollable` approval gate (the
  Play review already happened out of band). Mirrors `promoteH`'s pre-promote-snapshot adoption.
  Fixes "Cannot set rollout from state MBCompleted" when bulk-setting % on Console-started
  rollouts. `isObservedRollout` in `Handlers/Rollout.hs`.
- **App Monitor reflects every action immediately** — the monitor reads the `store_status`
  cache, not `release_tracker`, so it used to lag the release list after an action (a **halt**
  showed on the list but not the monitor). Now every handler (set / halt / resume / release-all /
  promote / mark-approved / mark-rejected / withdraw, both platforms) **mirrors** its new
  production state into `store_status` with no extra store edit, and the FE invalidates
  `['store-monitor']`. Full mechanism + rationale (why mirror, not re-poll): monitoring plan §10.
- **Authoritative rollout columns end-to-end** — `release_tracker`'s `rollout_status` /
  `rollout_percent` are injected into the list/detail `release_context` (`fromRow`) and carried
  through FE `normalizeRelease`, so the list, detail and bulk panel read the live % off the row
  (store-sync metadata only as fallback) instead of a stale snapshot.

---

## 14. Things to verify in dev BEFORE locking the design

1. **Does the raw Android Publisher API accept `userFraction = 1e-9`** (0.0000001%)? The
   team already submits at this near-zero % — but confirm it works via the **API** (not just
   the Console UI), since the validation path can differ and the docs cite a 1% UI floor.
   If rejected, lower `android_review_rollout_fraction` to the smallest accepted value.
2. **`reviewSubmissions` vs. the legacy `appStoreVersionSubmissions`** — confirm which works
   for our App Store Connect account/team and use the modern one.
3. **Provider iOS gap** — the prod lane only uploads to TestFlight, so there is no App Store
   version to submit. Two ways to fix, decide later:
   - SCC creates the App Store version itself, attaches the latest TestFlight build, then
     submits (no fastlane change, more SCC code), **or**
   - a one-line fastlane change to `upload_to_app_store`.
   Ship Android + consumer iOS first; handle provider iOS as a fast-follow.

---

## 15. Decisions already locked

- **Model A** (SCC owns promote + rollout) — confirmed by the fastlane scripts. No fastlane
  change needed for Android or consumer iOS.
- **Promote is operator-gated** (a button), not automatic.
- **Never auto-release after approval** — operator clicks "Roll out" / "Release."
- **Android "held" = submit at ~0%** (`userFraction 1e-9`, config `android_review_rollout_fraction`) —
  replicates the team's proven manual approach; supersedes the earlier 1%-canary / halted ideas.
- **Android review/rejection is manual** — operator marks approved/rejected; SCC can't auto-detect.
- **Reuse existing auth** — Play JWT/OAuth and Apple ES256 are done and correct.
- **v1 is notes-only** — promote pushes only What's New (from the changelog `summary_short`)
  + `releaseType: MANUAL` + the Android rollout fraction; reviewer contact, demo account,
  notes and export compliance **defer to the store's carried-forward values**. The per-app
  `app_store_submission_config` table is **deferred to Phase 2** (§6a), added only when a real
  override / onboarding need appears.
- **v1 migration is 0026** (repo is at 0025); the `0027` config table is deferred.

---

## Appendix — verified API references

- Google Play — `edits.commit` (`changesNotSentForReview` holds from review): <https://developers.google.com/android-publisher/api-ref/rest/v3/edits/commit>
- Google Play — `edits.tracks` (staged rollout `userFraction` / release status): <https://developers.google.com/android-publisher/api-ref/rest/v3/edits.tracks>
- Google Play — staged rollouts (UI 1%–100% guidance): <https://support.google.com/googleplay/android-developer/answer/6346149?hl=en>
- Google Play — check your app's policy status (rejection is shown in Console, not API): <https://support.google.com/googleplay/android-developer/answer/9842754?hl=en>
- Apple — App Store Version Release Requests (manual release): <https://developer.apple.com/documentation/appstoreconnectapi/app-store-version-release-requests>
- Apple — POST appStoreVersionReleaseRequests: <https://developer.apple.com/documentation/appstoreconnectapi/post-v1-appstoreversionreleaserequests>
- Apple — Select a version release option (manual + phased behaviour): <https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/>

---

## 16. iOS Store-Sync Ref Capture (changelog baseline)

> Consolidated here from the former standalone `2026-06-12-ios-store-sync-ref-capture.md`.
> **Status:** R1+R2 built & green; R3+R4 pending. **Fixes:** empty "Commits since last release"
> on the first SCC-built iOS release.

### 16.1 The problem

On the create-mobile-release page, the **"Commits since last release"** panel for an iOS app
shows *"No commits found (no previous release to compare against)."* even though commits
clearly exist. This is **not** "no changes" (that would read *"Branch is identical…"*, status
`identical`) — it's **no baseline ref to diff against**.

**Root cause** (`Handlers/Release.hs:514-521`): the changelog diffs the source branch against
the previous release's git ref —
```
baseRef = previous release's  tag_pushed   (if present)
       else previous release's commit_sha   (if present)
       else ""   → emptyPreview  (status "unknown")
```
The previous iOS release is typically a **store-synced row**, and iOS store-sync records
**neither a tag nor a commit**:

`StoreSync.insertSyntheticRelease` derives the tag from the version *code*:
```haskell
derivedTag = case mCode of
    Just code | surface=="driver" -> Just (acName <> "-v" <> version <> "-" <> show code)
              | otherwise          -> Just (segment <> "/prod/" <> platform <> "/v" <> version <> "+" <> show code)
    Nothing   -> Nothing            -- iOS passed Nothing → no tag
-- and rtCommitSha = Nothing on every store-sync row
```
`syncIos` historically called `insertSyntheticRelease ac ver Nothing` — **no code → no tag**.
Android works because `syncAndroid` passes `Just (tiCode production)`, so it derives
`{app}/prod/android/v{version}+{code}` and the diff has a baseline. The iOS tag *scheme already
exists* in `derivedTag`; it only yielded `Nothing` because the build number (the iOS equivalent
of `versionCode` — CFBundleVersion) was never fetched.

### 16.2 Goal

iOS store-sync rows should carry a **comparable git ref** (a tag and, ideally, its resolved
commit), so the changelog diff works on the **first SCC-built iOS release** for an app whose
prior history is store-synced — exactly like Android. Best-effort and **never a regression**:
if no ref can be found, behave as before (empty first preview).

### 16.3 Approach

**Core (mirror Android):** fetch the iOS **build number** from App Store Connect and pass it
as `mCode` so the *existing* `derivedTag` template produces
`{segment}/prod/ios/v{version}+{buildNumber}` (consumer) / `{acName}-v{version}-{buildNumber}`
(provider). One value unlocks the whole thing.

**Hardening (durability + resilience):**
- **Verify + resolve commit** — after deriving the tag, best-effort look it up via the existing
  `GET /git/matching-refs/tags/{prefix}` + `getCommitInfo`; if it resolves, also store
  `commit_sha` (immutable — survives tag deletion/moves; also helps revert).
- **Prefix fallback** — if the *exact* derived tag isn't found (build-number mismatch / different
  suffix), search `matching-refs/tags/{segment}/prod/ios/v{version}` and take the best
  (highest-suffix) match. Recovers the baseline without knowing the exact code.

**Fallback of last resort:** no tag and no commit → store `NULL` (prior behavior).

### 16.4 ⚠ The one thing to verify first

**Confirm the iOS CI's actual tag scheme in `ny-react-native`.** This fix assumes the iOS lane
pushes `{segment}/prod/ios/v{version}+{buildNumber}` (consumer) / `{acName}-v{version}-{buildNumber}`
(provider) — the same convention `execConfirmTag` uses. If the iOS lane tags differently:
adjust the template, rely on the **prefix fallback** (§16.3, matches by `v{version}` regardless of
suffix), or make the template a config (`mobile_ios_store_sync_tag_template`).

### 16.5 Backend changes

| Module | New/extend | Responsibility |
|---|---|---|
| `Versioning/Apple.hs` | done (R1) | `BuildsResp` parses the **build number** — `data[0].attributes.version` from `/v1/builds` — alongside the marketing version; `fetchAscBuildInfo` returns `AscBuildInfo {abiVersion, abiBuildNumber}`. |
| `Mobile/StoreSync.hs` | done (R2) | `syncIos` parses the build number to `Int32` and passes it as `mCode`; the existing `derivedTag` fires. (R3) resolve + store the tag's commit via the GitHub client. |
| `Mobile/Github.hs` | reuse | existing `matching-refs/tags/{prefix}` + `getCommitInfo` for verify/resolve/fallback. |

**Data captured on the iOS synthetic row** (no schema change):
- `target_state.mbcTagPushed` ← derived iOS tag (the changelog's preferred `baseRef`).
- `target_state.mbcVersionCode` ← the build number (CFBundleVersion; informative — iOS revert
  orders by semver, so this doesn't disturb ordering).
- `release_tracker.commit_sha` ← resolved commit (R3 hardening; durable fallback `baseRef`).

The ASC build-number parser is **pure** → unit-tested (`[36]` in `test/Main.hs`).

### 16.6 Backfill (existing rows)

Existing iOS store-sync rows have `tag_pushed = NULL` / `commit_sha = NULL`. A one-off backfill
resolves refs for them so apps benefit immediately: for each iOS `MobileBuild` row with
`mode='STORE_SYNC'` and null tag, derive the prefix from `(app, version)`, search GitHub
`matching-refs`, and `UPDATE` the row's `target_state.mbcTagPushed` (+ `commit_sha`). Ship as an
idempotent script under `backend/scripts/` (pattern: `backfill-revert-data.sh`), dry-run first.

### 16.7 Edge cases

1. **Build number unavailable** → `Nothing` → prior behavior (no regression).
2. **Tag doesn't exist in GitHub** → `compareRefs` already fails gracefully → `emptyPreview`; the prefix fallback (§16.3) tries to recover.
3. **Provider iOS** (`surface='driver'`) → the existing `driver` template branch handles it once `mCode` is supplied.
4. **Non-integer build number** → parse defensively; unparseable → prefix search (version-only), else `NULL`.
5. **Multiple builds share a marketing version** → prefix search picks the highest suffix (the live build).
6. **Tag later deleted/moved** → the resolved `commit_sha` survives as the durable `baseRef`.
7. **Don't break Android** — change isolated to `syncIos`; `syncAndroid` untouched.

### 16.8 Build order (roadmap)

- [x] **R1 — ASC build number** — `BuildsResp` parses marketing version + build number; `fetchAscBuildInfo` → `AscBuildInfo`. Test `[36]`. `fetchAscVersions` kept as a thin `abiVersion` wrapper.
- [x] **R2 — Derive the iOS tag** — `syncIos` passes the parsed build number as `mCode`; `derivedTag` fires (`{segment}/prod/ios/v{version}+{code}`); unparseable → `Nothing` (graceful). ⏳ Verify against a real app: does the changelog populate on the next iOS sync? (Depends on the iOS CI tag scheme — §16.4.)
- [ ] **R3 — Verify + resolve commit** — best-effort `matching-refs`/`getCommitInfo`; store `commit_sha`; prefix fallback.
- [ ] **R4 — Backfill** — idempotent script over existing NULL iOS store-sync rows.

R1+R2 are the minimal fix (changelog works going forward). R3 adds durability; R4 fixes the back-catalog.

### 16.9 Decisions & risks

- **Reuse the existing tag scheme** — feed `derivedTag` the build number; minimal, symmetric with Android.
- **Best-effort, never a regression** — every failure path lands on prior behavior (`NULL` ref → empty first preview).
- **Risk:** the iOS CI tag scheme (§16.4) — verify in `ny-react-native`; the prefix fallback de-risks it.
- **Store commit, not just tag** — durable baseline + helps the revert flow.
- **iOS `version_code` now populated** for store-sync rows (the build number) — harmless: iOS ordering uses semver, not the code.
