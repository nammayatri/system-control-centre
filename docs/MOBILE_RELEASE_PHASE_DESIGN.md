# Mobile release lifecycle — single source of truth (ReleasePhase)

**Date:** 2026-06-25 (§16 added 2026-07-02)
**Status:** SHIPPED — §3–§5, §14–§15 (`Lifecycle/` modules, `setPhase`, store-status
SSOT read path) and **§16 including all six §16f slices + the §16h Android rules**.
The doc is the design + decision record for what is now in code.
**Motivation:** Kill the "internally-inconsistent row state" bug class
(e.g. a row showing `IN REVIEW` + `rolling out 1%` at once — see
[`MOBILE_SLOT_SUPERSESSION_AUDIT.md`](./MOBILE_SLOT_SUPERSESSION_AUDIT.md)) by
making the row's lifecycle a **single canonical value** that everything else is
derived from — so the contradiction is unrepresentable, not just patched.

---

## 1. Problem recap

A row's status is stored **redundantly** across independent fields:
`mb_wf_status` (JSON), `review_status`, `rollout_status`, `rollout_percent`,
`store_track` (column **and** a `metadata` mirror). Each transition is applied by a
**piecemeal setter** that touches a subset, and each **surface** (list, detail,
monitor, supersession queries) re-derives "status" from a *different* subset with
*different* precedence. Result: rows hold self-contradictory combinations, and two
screens disagree for the same row.

Root cause: status is a **product** of independent fields, so illegal combinations
(`review_status='in_review'` AND `rollout_status='rolling_out'`) are representable;
nothing re-establishes the whole tuple on a transition; precedence lives only in the
FE `stageOf`.

---

## 2. Principle

> **Single writer, single deriver, illegal states unrepresentable.**

Make the status a **sum type** (one value, mutually-exclusive states) instead of a
product of columns. Store it once; derive everything else from it via pure
functions; reconcile the store's observed truth **into** it.

This is the codebase's own philosophy applied to the release row: ADTs not Text,
transitions enforced by a `validNext` table, totality + `-Wall` catching missing
cases at compile time.

---

## 3. Two axes: build kind × phase

A mobile build has two independent dimensions. Conflating them is why the current
code scatters `isDebug` / `isFirebase` / `claimsStoreIdentity` / `destination`
checks across `Workflow.hs`, `Rollout.hs`, `Tracker.hs`, `StoreSync.hs`.

### 3a. Build kind — does it have a store lifecycle at all?

```haskell
data BuildKind = Debug | FirebaseInternal | StoreBound deriving (Eq, Show)

-- The ONE classifier — replaces the scattered checks.
buildKind :: MobileBuildContext -> BuildKind
buildKind c
  | isDebugBuildType (mbcBuildType c)   = Debug              -- master/QA, debug apps
  | mbcDestination c == Just "Firebase" = FirebaseInternal   -- provider/driver Firebase
  | otherwise                           = StoreBound         -- consumer android/ios + provider GooglePlay

hasStoreIdentity :: BuildKind -> Bool
hasStoreIdentity StoreBound = True
hasStoreIdentity _          = False
-- The existing `claimsStoreIdentity c` becomes: hasStoreIdentity (buildKind c)
```

`hasStoreIdentity` is *eligibility* (a non-debug, non-Firebase build). Whether a row
**actually holds** the version-code identity slot also depends on its phase — see
§3d.

This partition is exactly today's behaviour, just centralised:

| Build | build_type | destination | BuildKind | version_code | store lifecycle |
|-------|-----------|-------------|-----------|--------------|-----------------|
| Debug (master, debug apps) | `debug` | (Firebase/TestFlight) | `Debug` | none | **no** |
| Provider driver Firebase | `release` | `Firebase` | `FirebaseInternal` | none (timestamp version) | **no** |
| Consumer android/ios | `release` | `null` | `StoreBound` | yes | yes |
| Provider GooglePlay | `release` | `GooglePlay` | `StoreBound` | yes | yes |

### 3b. Phase — the store sub-lifecycle (StoreBound only)

```haskell
data ReleasePhase
  = Building
  | BuildFailed Text
  -- Non-store TERMINALS — Debug + Firebase. No review/rollout, ever.
  | Distributed BuildKind          -- Distributed Debug | Distributed FirebaseInternal
  -- Store sub-lifecycle (only reachable from a StoreBound build):
  | InternalHeld                   -- on Play internal / iOS TestFlight, promotable
  | InReview
  | Approved                       -- approved, held (not released)
  | RollingOut Double              -- live & ramping at this fraction (0,1)
  | Halted Double
  | Live                           -- 100% / completed
  | Rejected Text
  | Superseded
  | Aborted
  deriving (Eq, Show)
```

Two design wins fall straight out of the type:

1. **The fraction lives inside `RollingOut`/`Halted`.** So "in review" and
   "rolling 1%" are mutually exclusive *by type* — the Cumta contradiction can't be
   constructed.
2. **`Distributed Debug` / `Distributed FirebaseInternal` are terminal.** A
   debug/Firebase build reaches one at build-complete and the store lifecycle code
   (promote / rollout / reconcile, all gated on `hasStoreIdentity`) never touches
   it. This is the **"don't break debug"** guarantee, now expressed in the type
   instead of scattered `if isDebug` guards.

### 3c. Legal transitions (defined on constructor TAGS)

Transitions must be defined on a **payload-free tag**, not on the full `ReleasePhase`.
`ReleasePhase` derives `Eq`, which compares the `Double`/`Text` payloads — so a
value-level membership check (`RollingOut 0.5 \`elem\` [RollingOut 0]`) is `False`, and a
legitimate **% bump** (`RollingOut 0.01 → RollingOut 0.5`) or a `BuildFailed "ci error"`
would be wrongly rejected. Tagging fixes that:

```haskell
data PhaseTag
  = TBuilding | TBuildFailed | TDistributed
  | TInternalHeld | TInReview | TApproved
  | TRollingOut | THalted | TLive | TRejected | TSuperseded | TAborted
  deriving (Eq, Show)

phaseTag :: ReleasePhase -> PhaseTag
phaseTag = \case
  Building -> TBuilding;  BuildFailed _ -> TBuildFailed;  Distributed _ -> TDistributed
  InternalHeld -> TInternalHeld;  InReview -> TInReview;  Approved -> TApproved
  RollingOut _ -> TRollingOut;  Halted _ -> THalted;  Live -> TLive
  Rejected _ -> TRejected;  Superseded -> TSuperseded;  Aborted -> TAborted

validNext :: PhaseTag -> [PhaseTag]
validNext TBuilding     = [TInternalHeld, TDistributed, TBuildFailed, TAborted]
validNext TInternalHeld = [TInReview, TSuperseded, TAborted]
validNext TInReview     = [TApproved, TRejected, TAborted]
validNext TApproved     = [TRollingOut, TLive, TSuperseded, TAborted]
validNext TRollingOut   = [TRollingOut, THalted, TLive, TSuperseded]  -- TRollingOut→TRollingOut = a % bump
validNext THalted       = [TRollingOut, TLive, TSuperseded]
validNext _             = []   -- terminals: Distributed, Live, Rejected, Superseded, Aborted, BuildFailed

canTransition :: ReleasePhase -> ReleasePhase -> Bool
canTransition cur next = phaseTag next `elem` validNext (phaseTag cur)
```

The post-build branch is chosen from `buildKind`, so a `FirebaseInternal` build can
**only** go `Building → Distributed FirebaseInternal` — `InReview` is unreachable.

### 3d. Version-code identity is phase-gated (failed builds release it)

A `StoreBound` build occupies a unique `(app_group, service, env, version,
version_code)` slot — that's the version-code identity (migration 0035/0036). But it
should occupy it **only while the build hasn't failed**. A build that aborts or fails
**before it ships** never consumed that code at the store, so a retry with the *same*
version + code must be allowed (this is the original `23505`-on-retry-after-abort bug).

The arbiter of real store-code uniqueness is the **store itself** — once a code is
uploaded, Play/ASC permanently reject it and version-resolution advances past it. So
SCC must not block a retry the store would accept. The rule:

```haskell
-- A failed terminal never shipped → it releases its identity slot.
isFailedTerminal :: ReleasePhase -> Bool
isFailedTerminal = \case
  Aborted     -> True
  BuildFailed _ -> True
  _           -> False

-- Whether THIS row holds the version-code identity slot right now.
holdsStoreIdentity :: BuildKind -> ReleasePhase -> Bool
holdsStoreIdentity kind phase = hasStoreIdentity kind && not (isFailedTerminal phase)
```

The `version_code` **column** (the identity; the code is always kept in the
target-state JSON for display) is written iff `holdsStoreIdentity`. Note the code value
itself is **build data, not phase-derivable**, so this gate is *not* part of the
phase-only `project` (§4) — it's a separate write `identityCode :: BuildKind ->
ReleasePhase -> Maybe Int32 -> Maybe Int32` that `setPhase` applies (phase + kind gate
the *actual* code from the build). So when a build transitions to `Aborted` /
`BuildFailed`, its `version_code` column is cleared → it drops out of the unique index →
a new build can reuse the same version + code. `Rejected` / `Superseded` / live phases
keep their slot (they reached the store; the store would advance the code anyway, so no
real collision occurs).

> Note: `Aborted` reached from `InReview`/`Approved` (a withdraw) *did* upload to the
> store, so releasing its slot is harmless rather than necessary — the store still
> guards the real code, and re-resolution advances past it. Releasing on every failed
> terminal is the simple, safe rule; the store is the final arbiter.

---

## 4. Projections — the single deriver

The denormalised columns become a **derived cache**, written **only** through
`project`. No code sets them individually.

```haskell
data Projection = Projection
  { pReview   :: Maybe Text   -- review_status:  in_review | approved | rejected | NULL
  , pRollout  :: Maybe Text   -- rollout_status: rolling_out | halted | completed | superseded | NULL
  , pPercent  :: Maybe Double -- rollout_percent
  , pTrack    :: Maybe Text   -- store_track:    internal | production | NULL
  }

project :: ReleasePhase -> Projection
project = \case
  Distributed _ -> Projection Nothing  Nothing             Nothing       Nothing
  InternalHeld  -> Projection Nothing  Nothing             Nothing       (Just "internal")
  InReview      -> Projection (Just "in_review") Nothing   Nothing       (Just "production")
  Approved      -> Projection (Just "approved")  Nothing   Nothing       (Just "production")
  RollingOut p  -> Projection Nothing (Just "rolling_out") (Just (p*100)) (Just "production")
  Halted p      -> Projection Nothing (Just "halted")      (Just (p*100)) (Just "production")
  Live          -> Projection Nothing (Just "completed")   (Just 100)    (Just "production")
  Superseded    -> Projection Nothing (Just "superseded")  Nothing       (Just "production")
  Rejected r    -> Projection (Just "rejected") Nothing    Nothing       (Just "production")
  _             -> Projection Nothing  Nothing             Nothing       Nothing
```

Note `project InReview` ⇒ `rollout_status = NULL`, and `project (RollingOut _)` ⇒
`review_status = NULL`. The stale-sibling bug is gone at the source.

One display projection used by **every** surface (list, detail, monitor), so they
can never disagree:

```haskell
data Display = Display { dLabel :: Text, dVariant :: Variant }

displayStatus :: ReleasePhase -> Display
displayStatus = \case
  Distributed FirebaseInternal -> Display "Firebase internal" Amber
  Distributed Debug            -> Display "Debug build"       Zinc
  InternalHeld                 -> Display "Ready to promote"  Blue
  InReview                     -> Display "In review"         Purple
  Approved                     -> Display "Approved · held"   Success
  RollingOut p                 -> Display ("Rolling out " <> pct p) Info
  Halted p                     -> Display ("Halted · " <> pct p)    Warning
  Live                         -> Display "Released · 100%"   Success
  Rejected _                   -> Display "Rejected"          Danger
  Superseded                   -> Display "Superseded"        Default
  _                            -> Display "Building"          Default
```

### 4a. The complete projection — every status-bearing field

For the phase to be *the* source of truth, **every** field that encodes status must be
projected from it — not just the four above. Three more belong in `Projection` /
`setPhase`, or the phase is only *mostly* canonical:

**1. `rt_status` (generic `ReleaseStatus` column: `INPROGRESS` / `COMPLETED` /
`ABORTED` / `USER_ABORTED`).** This is a second status field next to the phase, today
mapped only at Finalize (Workflow stage 7). Project it so it can never disagree:

```haskell
pEngineStatus :: ReleasePhase -> ReleaseStatus
pEngineStatus = \case
  Building          -> INPROGRESS
  InternalHeld      -> INPROGRESS          -- held, runner still owns it
  InReview          -> INPROGRESS
  Approved          -> INPROGRESS
  RollingOut _      -> INPROGRESS
  Halted _          -> INPROGRESS
  Live              -> COMPLETED
  Superseded        -> COMPLETED
  Rejected _        -> ABORTED
  Aborted           -> USER_ABORTED
  BuildFailed _     -> ABORTED
  Distributed _     -> COMPLETED           -- debug / Firebase: terminal, done
```

`setPhase` writes `rt_status` from this, so the engine status and the lifecycle phase
move together (no more "INPROGRESS but actually rejected" skew). **Ownership:** for
mobile builds `setPhase` becomes the sole writer of `rt_status`; the generic
Runner/engine defers (its Finalize stage stops setting it for `MobileBuild` rows, so the
two never fight).

**2. Retire the `metadata` rollout mirror (audit bug #8).** `setProductionRolloutReflection`
writes `rollout_status` / `rollout_percent` into `metadata` *in addition to* the
columns — a second writer of the same state. Under this design **`setPhase` owns the
rollout state** (columns, projected from the phase). The metadata mirror is **dropped**;
the FE fallback `lifecycleFromRelease` (`meta?.rollout_status ?? …`) loses its
`metadata` branch and reads the column (now always authoritative). One writer, one
reader.

**3. `promotable` is a phase-derived property, not a parallel flag.** "Can promote now"
= the phase is promotable **and** the build is ahead of production. Today it's computed
in two places (`rdPromotable`, `injectPromotable`). Make it one helper so the rule lives
once:

```haskell
-- promotableStage: held on internal/tag-push, nothing started yet.
promotableStage :: ReleasePhase -> Bool
promotableStage InternalHeld = True
promotableStage _            = False

promotableOf :: ReleasePhase -> StoreCmp -> Bool      -- StoreCmp = is the build ahead of prod?
promotableOf phase cmp = promotableStage phase && aheadOfProduction cmp
```

Both `rdPromotable` (detail) and the list's `promotable` flag call `promotableOf`, so
they can't drift — same pattern as `displayStatus` for the badge.

> With these folded in, **every** status-bearing field — `review_status`,
> `rollout_status`, `rollout_percent`, `store_track`, `version_code` (identity),
> `rt_status`, the rollout mirror, and the `promotable` flag — is a pure function of the
> one `ReleasePhase`. Nothing about a mobile build's status is decided in more than one
> place.

---

## 5. The single writer

Delete the public piecemeal setters (`setReviewSubmitted`, `setReviewDecided`,
`setRolloutState`, `markReleaseInProgress`, `setMobileWfStatus`). The only mutator:

```haskell
setPhase :: Id Release -> ReleasePhase -> Flow ()
setPhase rid next = do
  cur <- phaseOfRow <$> loadRow rid
  unless (canTransition cur next) $ throwM (BadRequest (illegalTransition cur next))  -- tag-based (§3c)
  let Projection rv ro pct trk = project next
  -- ONE atomic UPDATE: mb_wf_status (the phase) + review/rollout/percent/store_track
  -- + rt_status (pEngineStatus, §4a) — the full projected tuple, together.
  writeRowPhase rid next rv ro pct trk (pEngineStatus next)
```

Every transition — operator action, workflow stage, store-sync reconcile — funnels
through `setPhase`, so the columns can never drift from the phase.

---

## 6. Reconciling store truth into the phase

The store is authoritative for the **rollout / live** dimension — but **NOT** for the
Android **review verdict**. Play review is opaque: `in_review` and `approved-held` both
sit parked below the 1% floor, so the store cannot tell them apart. A naive
"store always wins" would map a parked version back to `InReview` on every sync and
**clobber an operator's recorded `Approved`/`Rejected`** (a regression — the current
code guards against exactly this in `reconcileExternalReviewMapped`'s `mExisting`).

So the reconcile **merges** the current phase with the observation rather than
overwriting it:

```haskell
-- Store-observable dimensions only.
observedRollout :: StoreObservation -> Maybe ReleasePhase   -- ramp ≥1% ⇒ RollingOut f; 100% ⇒ Live; halted ⇒ Halted f
observedReview  :: StoreObservation -> Maybe ReleasePhase   -- Android inferred pending ⇒ InReview (best-effort)

reconcileObservation :: ReleasePhase -> StoreObservation -> ReleasePhase
reconcileObservation cur obs = case observedRollout obs of
  Just live  -> live                         -- a real ramp / 100% → STORE WINS (RollingOut / Halted / Live)
  Nothing    -> case cur of
    Approved   -> Approved                    -- operator already recorded the verdict — a store-inferred
    Rejected r -> Rejected r                  -- "pending" must NOT downgrade it back to InReview
    _          -> fromMaybe cur (observedReview obs)  -- else adopt the inferred review state

-- The reconciler calls:  setPhase rid (reconcileObservation cur obs)
```

A stale `review_status` on a genuinely-rolling version still self-heals (the rollout
branch wins and `project` nulls review — the Cumta fix), but an operator's `Approved`
is never clobbered by the opaque Android track. Rule of thumb: **store wins for
rollout, operator wins for the Android review verdict** (iOS review *is* observable
via ASC, so there `observedReview` is authoritative).

### 6a. Store-sync never mutates an SCC build's identity (history-preserving)

§6 reconciles the **phase**. The version/**code identity** is reconciled by a separate,
strictly **additive** rule — store-sync may *add* observed builds but must never
overwrite a build SCC recorded, or history is lost. Two facts make this safe:

- **An SCC (`MANUAL`) row's code is already authoritative.** `ResolveVersion` computes
  the code from the store, and `ConfirmTag` advances the row only when the matching
  pushed tag `…/v{version}+{code}` is found — a workflow that pushed a *different* code
  fails ConfirmTag (tag-timeout) rather than silently drifting. So the row's code is the
  code SCC actually built; there is no "create-time prediction vs upload" gap to repair.
- Therefore a store code that **differs from every SCC row** for that version is a
  **different, out-of-band build**, not a drifted copy of an SCC build.

The rule:

1. **store-sync never overwrites a `MANUAL` row's `version_code`.** Your `3.3.17+463`
   SCC build stays `463` forever — that's its history.
2. A store-observed `(version, code)` that **matches no existing row** is recorded as
   its **own** `STORE_SYNC` row. The unique `(version, code)` index allows it *alongside*
   the MANUAL row, so an out-of-band `3.3.17+464` becomes a **separate** row — you keep
   **both** the SCC `463` and the out-of-band `464`.
3. The in-place code bump (`updateStoreSyncBuildCode`) stays **`STORE_SYNC`-only**: a
   store-sync *snapshot* row (which just tracks "latest observed build") may bump in
   place, but a `MANUAL` build row never does.

> **Worked example.** You build `3.3.17+463` from SCC; someone uploads `3.3.17+464`
> out-of-band. Result: your `463` row is untouched (history kept), `464` is recorded as
> its own row. The monitor's internal cell shows `464` (latest by code, §14); the list
> shows **both** builds. Nothing is overwritten, nothing is lost.

So the corrected §6 reconcile in full: **the store is authoritative for the live/rollout
PHASE, but only ever ADDS to the IDENTITY history — it never rewrites a build SCC
recorded.** This is the key correction over an earlier "reconcile the code in place"
idea, which would have erased your `463` when an out-of-band `464` appeared.

---

## 7. Component structure (modularization)

Extract a cohesive `Products/Autopilot/Mobile/Lifecycle/`:

| Module | Responsibility | Subsumes |
|--------|----------------|----------|
| `Lifecycle/BuildKind.hs` | `BuildKind`, `buildKind`, `hasStoreIdentity` | scattered `isDebugBuildType` / `isFirebase` / `claimsStoreIdentity` / destination checks |
| `Lifecycle/Phase.hs` | `ReleasePhase`, `validNext`, `project`, `displayStatus`, `phaseOfRow` — **pure, unit-tested** | FE-only `stageOf`, ad-hoc column reads in the monitor |
| `Lifecycle/Transition.hs` | `setPhase` — the single guarded writer | `setReviewSubmitted` / `setReviewDecided` / `setRolloutState` / `markReleaseInProgress` / `setMobileWfStatus` (made private) |
| `Lifecycle/StoreReconcile.hs` | `observedToPhase` — store truth → phase | the rollout-reconcile + external-review mapping in `StoreSync.hs` |

The handlers (`Rollout.hs`) and the workflow (`Workflow.hs`) shrink to: classify
with `buildKind`, decide the next `ReleasePhase`, call `setPhase`. No surface reads
raw columns anymore.

---

## 8. API design

All three surfaces return the same canonical fields; the FE renders, never
re-derives:

```jsonc
{
  "phase": "rolling_out",
  "phasePercent": 1.0,
  "buildKind": "store_bound",
  "displayStatus": { "label": "Rolling out 1%", "variant": "info" },
  // projected, derived from phase — kept for back-compat, removed later:
  "reviewStatus": null, "rolloutStatus": "rolling_out", "storeTrack": "production"
}
```

Versioning is additive: ship `phase` / `displayStatus` alongside the existing
fields, migrate the FE to read them, then drop the old fields.

---

## 9. Database schema

- **SSOT:** reuse the existing `mb_wf_status` JSON as the phase store, extended so
  `RollingOut`/`Halted` carry the fraction (subsuming `rollout_status` /
  `rollout_percent`) and adding `Distributed BuildKind`. No new table.
- **Derived cache columns** (`review_status`, `rollout_status`, `rollout_percent`,
  `store_track`) stay, but only `setPhase` writes them — existing indexes
  (`findActiveRolloutReleases`, the supersession scope) keep working unchanged.
- **Supersession scope fix** (audit bug #4): key the scope on the phase
  (`store_track` projected from it), so a promoted SCC row with a NULL `store_track`
  column is no longer silently skipped.
- **Version-code identity (§3d):** the unique index stays
  `… WHERE category='MobileBuild' AND version_code IS NOT NULL`, but the column is now
  written iff `holdsStoreIdentity` — so a failed/aborted row carries `version_code =
  NULL` and frees the slot for a same-version+code retry. No index predicate change is
  needed (the column gate does it), which keeps the index decoupled from the status
  enum.
- **Migration `0039` (debug-safe):** backfill `store_track` from the derived phase;
  debug/Firebase rows classify as `Distributed _`; **NULL `version_code` for existing
  failed-terminal MobileBuild rows** so currently-stuck identity slots (an aborted
  build blocking a rebuild) are released. No destructive change — master / debug DB
  rows simply read as `Distributed Debug`.
  *(Shipped shape: the committed sequence carries structure only —
  `0034-mobile-store-sync-schema.sql` (columns + identity indexes) and
  `0035-staged-rollout-config.sql` (feature-flag seeds). The failed-terminal
  backfill + duplicate pruning are one-time remediation for pre-existing
  databases and live in the uncommitted `scripts/prod-upgrade-store-sync-ssot.sql`;
  a fresh database has nothing to fix — store sync refills it. The `store_track`
  backfill proved unnecessary: setPhase / store-sync populate it at runtime.)*

---

## 10. Caching strategy

- `store_status` stays the **observed** store cache (cooldown-gated Play/ASC read).
- **Invalidation = reconcile:** each sync maps `StoreObservation → ReleasePhase`
  and calls `setPhase`; store wins for live/rolling, so stale fields are overwritten
  on the next sync.
- `displayStatus` is a pure function of the cached phase — no extra reads.

---

## 11. Why this denies the bug class

1. **Illegal states unrepresentable** — a sum type can't be "review AND rolling".
2. **One writer** (`setPhase`/`project`) — columns can't drift.
3. **One deriver** (`displayStatus`) — surfaces can't diverge.
4. **Totality + `-Wall`** — a new phase that any projection/transition forgot to
   handle fails to compile.
5. **Build kind in the type** — debug/Firebase reach a terminal phase the store
   lifecycle can't touch, so the master/debug path is provably unaffected.

A future regression would require *constructing an illegal phase*, which won't
compile.

---

## 12. Migration plan (incremental, debug-safe)

1. Add `Lifecycle/BuildKind.hs` + `Lifecycle/Phase.hs` (pure, fully unit-tested).
   `claimsStoreIdentity` becomes `hasStoreIdentity . buildKind` — no behaviour change.
2. Add `setPhase`; route the **rollout/review** transitions through it (keep the
   columns as a derived cache; all current queries keep working). `setPhase` projects
   the **complete** field set (§4a): `review_status`, `rollout_status`,
   `rollout_percent`, `store_track`, **`rt_status`**, and it **owns the rollout state**
   so the `metadata` rollout mirror is dropped (audit bug #8).
3. Switch the **monitor** to `displayStatus` (kills the list-vs-monitor
   disagreement and the stale-review display, bugs #1–3).
4. Fix the supersession scope to key on the phase (bug #4). Replace `rdPromotable` /
   `injectPromotable` with the single `promotableOf` helper (§4a).
5. Move the **build-complete** branch to choose the post-build phase from
   `buildKind` (`Distributed Debug` / `Distributed FirebaseInternal` / `InternalHeld`).
   Verify debug/Firebase rows never enter `setPhase` again.
6. **Gate the `version_code` column on `holdsStoreIdentity`** (§3d) so the abort/fail
   transition clears it, plus the `0039` backfill that NULLs existing failed-terminal
   rows (shipped in the uncommitted prod-upgrade script — see the migration note
   above). This closes the `23505`-on-retry-after-abort independently of the rest and
   can ship as its own slice.
7. (Later) drop the cache columns; derive at read for full normalisation.

Steps 1–4 land the high-severity fixes without touching the build path; step 5
formalises the debug/Firebase terminals. Each step is independently shippable and
leaves debug builds (master DB, debug apps) on their existing path.

---

## 13. Scaling notes

All projection is per-row and pure — O(1), no new joins. The only store-touching
path is the sync reconcile, already cooldown-gated + single-flight. Multi-replica
writes racing on `setPhase` for the same app would be coalesced with a Postgres
advisory lock per `(app_group, service, env)` — the same mechanism the on-demand
refresh path already documents.

---

## 14. Store-read single source of truth (representative release per track)

A sibling of the row-state SSOT: the **store read** itself has a dual-source bug. The
same Play `releases[]` array is reduced to a "representative release" by *two
different* picks, so the App Monitor and the release/next-version paths can disagree.

### 14a. The bug — Android internal cell goes stale

| Consumer | Path | Internal pick |
|----------|------|---------------|
| Monitor **internal cell** (`store_status`) | `bodiesToSnapshots` → `parseTrackSnapshot "internal"` | `pickRolloutRelease` (Play.hs:751) |
| Next-version / release list (`recordAndroidTracks`) | `bodiesToTracks` → `decodeTrackInfo` → `pickRelease` | `pickLiveRelease` (Play.hs:808,436) |

`pickRolloutRelease` returns the first `inProgress`/`halted` release, else the **first
array element** — no `higherCode` selection. Internal-track releases aren't staged
rollouts, so it falls to the first element of `releases[]`. Play does **not** guarantee
array order, and a new internal build can appear as a separate release, so with two
releases on internal (old `+460` and new `+463`) the monitor can stay at `+460` while
the next-version path (using `pickLiveRelease`'s highest-completed-code) sees `+463`.
Two paths, two answers, same data — the monitor's internal cell silently lags the
latest build.

### 14b. The fix — one representative-release pick, used by both paths

```haskell
-- Latest build on a non-rollout track (internal / TestFlight) = highest version code,
-- regardless of status or array order. Fixes the "first element" staleness.
pickLatestByCode :: [Release] -> Maybe Release
pickLatestByCode [] = Nothing
pickLatestByCode rs = Just (foldl1 higherCode rs)
  where higherCode a b = if maxVersionCode (rVersionCodes a) >= maxVersionCode (rVersionCodes b) then a else b

-- ONE representative-release pick per track — used by parseTrackSnapshot AND
-- decodeTrackInfo, so the monitor cell and next-version/release-list can never diverge.
representativeRelease :: Text -> [Release] -> Maybe Release
representativeRelease "production" = pickLiveRelease   -- what's SERVING users (unchanged)
representativeRelease _            = pickLatestByCode  -- internal / testflight: latest build
```

- `parseTrackSnapshot track` uses `representativeRelease track` (replaces the
  `pickRolloutRelease` branch for non-production).
- `bodiesToTracks` threads the track name: `decodeTrackInfo "internal" i` /
  `decodeTrackInfo "production" p`, both via `representativeRelease`.
- Production semantics are untouched (`pickLiveRelease` — a 5% ramp still beats a
  parked near-zero review release).

### 14c. iOS — already correct (no equivalent bug)

iOS reads no client-side array. Both the monitor TestFlight cell (`fetchAscSnapshots`)
and the iOS next-version (`getLatestTestFlightVersion`) ask ASC for the latest build
**server-side**:

```
GET /v1/builds?filter[app]=…&filter[expired]=false&sort=-uploadedDate&limit=1&include=preReleaseVersion
```

ASC returns the single most-recently-uploaded build, so "latest TestFlight" is
authoritative and both paths agree by construction. The representative-build-per-track
notion is defined once (the ASC sort query). No fix needed — just keep both iOS paths on
that same query.

> Platform-appropriate criterion: Android internal = highest version **code**; iOS
> TestFlight = most recent **upload date** (iOS build numbers reset per version, so date
> is the right ordering). Both express "the latest build available to testers."

### 14d. Implementation steps (independent slice)

1. Add `pickLatestByCode` + `representativeRelease` to `Versioning/Play.hs`.
2. Wire `parseTrackSnapshot` and `bodiesToTracks`/`decodeTrackInfo` through
   `representativeRelease` (thread the track name into `bodiesToTracks`).
3. Unit test: a multi-release internal body with the **older** release first must yield
   the **higher** code (locks in the order-independence).
4. iOS: no code change; assert both iOS paths use the same `sort=-uploadedDate&limit=1`
   query so they can't drift.

This is independent of the phase model and can ship on its own.

---

## 15. UI single source of truth: version + status badge

The "surfaces disagree" problem isn't only in the backend columns — the **frontend
re-derives the status badge four separate times**, each from different inputs with its
own precedence, and formats the version/percent ad-hoc in ~8 places. This is where
"version with badge status" drifts between screens.

### 15a. The duplication inventory

**Four parallel status → badge mappings** (each re-encodes "rollout beats review", etc.):

| # | Site | Input | Used by |
|---|------|-------|---------|
| 1 | `mobileStage.ts` — `stageOf` / `mobileDisplayStatus` | `release_context` / `RolloutDetail` (mb_wf_status + columns) | list rows, detail panel |
| 2 | `storeBadge.ts` — `deriveStoreBadge` | `TrackCell` (store_status: status + reviewStatus + rolloutPercent) | App Monitor cells + `AppTrackModal` |
| 3 | `MobileRolloutPanel.tsx` — `StageBadge` (inline) | `stage` | rollout panel header |
| 4 | `ReleaseStatusBadge.tsx` | `release_context` + superseded/promotable | list rows |

They can disagree for the same row (the list-vs-monitor "Rolling out" vs "In review"
defect, §3 of the audit). Each duplicates the precedence ladder independently.

**Inconsistent formatters** (same value, different output):

- Version+code: `+460` (`ReleaseSummary.tsx:670`, `MobileAppsAdmin.tsx:84`,
  `CreateMobileRelease.tsx:83`) vs `(460)` (`LiveReleases.tsx:212`,
  `ReleaseSummary.tsx:1042`).
- Rollout %: `formatRolloutPercent` (`storeBadge.ts`) vs `toFixed(2)`
  (`MobileRolloutPanel.tsx:244`) vs `` `${pct}%` `` (`mobileStage.ts:142`).

### 15b. The SSOT plan

1. **Backend owns the status.** `displayStatus :: ReleasePhase -> Display` (§4) is the
   one definition. The **store-cell badge** (`deriveStoreBadge`) must derive from the
   *same* phase: map a `TrackCell` → `ReleasePhase` (`observedToPhase`, §6) →
   `displayStatus`, instead of its own precedence ladder. Then the monitor cell and the
   list badge are the same value by construction.
2. **Frontend renders, never re-derives.** Surfaces consume the backend
   `displayStatus` (`{label, variant}`); the four FE mappings collapse to **one**
   `<ReleaseStatusBadge>` that takes a phase/displayStatus. `StageBadge` and
   `deriveStoreBadge` are deleted.
3. **One formatter each.** `formatVersion(name, code)` (pick the canonical form — e.g.
   `v3.3.17 +460`) and `formatPercent(p)` replace the ~8 ad-hoc sites.
4. **One `<VersionBadge>` component** = `formatVersion` + the status badge, rendered
   identically by the list, detail, monitor cells, create preview, and apps admin —
   the literal "version with badge status" widget, defined once.
5. `FirebaseBadge` / `PlatformBadge` stay separate — they encode the **build kind** and
   **platform** axes (§3), orthogonal to the lifecycle badge, but belong to the same
   badge set.

### 15c. Modularization

Mirror the backend `Lifecycle/` on the frontend:

```
products/releases/lifecycle/
  phase.ts          -- Phase type + displayStatus render map (or just consume BE displayStatus)
  format.ts         -- formatVersion, formatPercent  (the one-formatter rule)
  VersionBadge.tsx  -- version + status badge, used everywhere
  ReleaseStatusBadge.tsx  -- the single badge component (absorbs StageBadge, deriveStoreBadge)
```

`mobileStage.ts`, `storeBadge.ts`, and the inline `StageBadge` fold into this; the
pages import `<VersionBadge>` / `<ReleaseStatusBadge>` and stop re-deriving.

### 15d. Why it closes the class

Today a status change must be replicated across 4 mappings + 8 formatters to stay
consistent — and isn't, so screens drift. After this, **the backend phase is the only
place status is decided**, the FE has **one** badge and **one** version formatter, and
"version with badge status" is identical on every surface by construction.

### 15e. Implementation steps (independent slice, ships after §4)

1. Backend: emit `displayStatus` (and `phase`) on list rows, `RolloutDetail`, and
   monitor cells (map the cell through `observedToPhase`).
2. Frontend: add `lifecycle/format.ts` (`formatVersion`, `formatPercent`) and migrate
   the ~8 formatting sites.
3. Frontend: add `<VersionBadge>` + one `<ReleaseStatusBadge>` rendering the backend
   `displayStatus`; delete `StageBadge`, `deriveStoreBadge`, and the `stageOf`-based
   badge derivations.
4. Verify list, monitor, detail, and the modal show identical labels for the same row.

---

## 16. One owner per fact — the logbook and the scoreboard

§1–§15 fixed how a single row's status is decided (one phase value, one writer, one
deriver). The bugs that remain — the in-review badge lag, review landing on the wrong
build's cell, a rollout's version_code clobbered to NULL, terminal stamps wiped at
completion — are one level up: they're **two TABLES copying facts from each other**,
and the copies going stale or landing on the wrong identity. This section fixes the
table layer the same way §5 fixed the row: one owner per fact, everything else derived.

### 16a. The idea in plain words

The system keeps two very different kinds of information, and they belong in two
different places:

- **`release_tracker` is the logbook.** One line per build that ever existed — who
  made it, its full identity (version **name** + build **number**), what was decided
  about it, and how it ended (released / superseded / rejected / aborted). Lines get
  **added** and eventually **stamped with a final outcome**. Old lines are never
  rewritten — that's the whole point of a logbook.
- **`store_status` is the scoreboard.** What Play / the App Store are showing **right
  now**, one cell per track (production / internal / TestFlight): which build sits
  there, at what rollout %. It's overwritten on every refresh and remembers nothing.

Today we copy scoreboard facts into the logbook (synthetic-row mirrors, % reflections)
and logbook facts onto the scoreboard (the review "overlay"). Every copy is a chance
to be stale (the in-review badge lag) or to land on the wrong line (review stamped
onto the *live* build's cell instead of the *incoming* build). The rule that deletes
the whole bug class:

> **Every fact has exactly one home. Screens JOIN the logbook and the scoreboard at
> read time — nobody reads a copy.**

| Question | One home | The only writers |
|---|---|---|
| "What builds exist / existed?" (version + build number, who made it, changelog) | logbook (`release_tracker` identity columns) | SCC create + ConfirmTag; store-sync when it **discovers** a build we didn't make (insert-only) |
| "What was decided about a build?" (promoted, review verdict, rollout lifecycle, final outcome) | logbook lifecycle columns | `setPhase` (§5) — including for out-of-band observations |
| "How is the build pipeline doing?" (CI stages) | logbook `release_context` JSON | the workflow engine, touching **only** its own columns |
| "What's on each store track right now?" | scoreboard (`store_status`) | store-sync snapshot upserts |
| "What badge / % / chip do we show?" | **nobody — computed** | `phaseFromFields(logbook row, scoreboard cells)` per request |

### 16b. Builds happen outside SCC too — the model must not care

Builds get uploaded from CI directly, submitted for review from the Play/ASC consoles,
ramped and released by hand. That is **normal input, not an edge case**: SCC is just
one of several actors pressing buttons at the store, and **store-sync is how every
actor's actions — ours included — become recorded facts.** Each out-of-band action
maps to the same two homes as an SCC action:

| Done outside SCC | How it lands (same paths as an SCC action) |
|---|---|
| **Build uploaded** (new version, or same version with a new build number) | Next sync **discovers** it → a new logbook line with full identity. §6a already guarantees discovery never rewrites a line SCC recorded — you keep both `3.3.17+463` (yours) and `+464` (theirs). |
| **Submitted to review** from the console | Sync reads the store's review state → recorded on the version's own line (discovered first if missing) via `setPhase InReview`. iOS is read authoritatively from ASC — **including the build number** (gap fixed in 16f-1). Android review is opaque, so it's inferred from the parked ~0% fraction and the operator's verdict wins (§6). |
| **Rollout started / ramped / halted** in the console | Sync updates the scoreboard cell (its fact) and the matching line **adopts** the lifecycle via `setPhase RollingOut/Halted` — after that it's tracked exactly like an SCC rollout. |
| **Released to 100%** | Scoreboard production cell now holds that build; its line is stamped `Live` (terminal `RELEASED`); the previously-live line is stamped `SUPERSEDED`. Both stamps are permanent logbook history. |
| **Rejected** | The line gets `Rejected` via `setPhase` (iOS authoritative; Android operator-marked). |

Same lines, same stamps, same deriver — only the **author** differs, and the author is
just data on the line (`created_by = 'store-sync'`, mode/origin marker), not a separate
lifecycle.

### 16c. What the App Monitor shows (three chips, zero copies)

Per app, straight from the owners:

| Chip | Source | Meaning |
|---|---|---|
| **Production** | scoreboard `production` cell | what users get right now: version+code, live %, halted/complete |
| **Internal** | scoreboard `internal` / `testflight` cell | the newest staged build: version+code |
| **Incoming** | logbook: the version promoted but not yet rolling (`in_review` / `approved` / `rejected`) — `listIncomingMobileVersions`, which the monitor already calls | what's between Internal and Production |

The review "overlay" (`findActiveMobileState` writing OUR review state INTO the
scoreboard, plus `mirrorProdReview` / `setProductionReviewStatus`) existed only because
the production/internal **cells** were asked to also display a logbook fact. Once
review is the Incoming chip's job, `review_status` leaves `store_status` entirely and
all three writers are **deleted** — and with them the lag class ("correct after a
while") and both wrong-identity overlay bugs.

### 16d. What the release list / detail shows

The logbook is the full **release history** — every build, SCC-made or discovered,
terminal lines frozen forever. The badge for a row:

```
terminal_status stamped              → the frozen outcome; no scoreboard join at all
row carries lifecycle (review/rollout) → phase from the ROW (immediate, no sync lag);
                                         live % joined from the (version, code)-matched
                                         production cell
otherwise                            → "Ready to promote" iff a pre-prod cell holds this
                                         exact (version, code); else Building/Distributed
```

Row-first for decisions, scoreboard-only for "which track / how far ramped". No fact
is read from two places, so no two screens can disagree — the §15 property, now
guaranteed at the table layer too.

### 16e. The write contract (the whole design in five lines)

1. **store-sync → scoreboard:** snapshot upserts only, always carrying **both** version
   and code. (Exception kept: after SCC itself edits a rollout, it may write the value
   it just set — that's warming a cache with a known store fact, not a second truth —
   but always with the row's full identity. The *review* mirror is gone; it was writing
   the incoming build's state onto the live build's cell.)
2. **store-sync → logbook:** INSERT discovery lines; every state change goes **through
   `setPhase`**; never rewrite an existing line's identity (§6a).
3. **workflow engine → logbook:** its own columns only. Concretely:
   `conditionalUpdateTracker`'s DELETE+re-INSERT rebuilds the whole row from `toRow`
   and **blanks every lifecycle column** (review, rollout, store_track,
   `terminal_status`) at completion/abort — it must become a column-scoped CAS UPDATE,
   like `persistWorkflowState`'s upsert already is.
4. **operators / SCC handlers → `setPhase`** (already true post-§5).
5. **Identity is total:** every line and every cell has version **and** code, enforced
   by the `(version, code)` unique indexes — which today exist **only in the dev DB**
   and get a real migration.

### 16f. Rollout order (independent, debug-safe slices)

1. **Identity completeness** — the identity schema is committed as the structure-only
   `0034-mobile-store-sync-schema.sql` (columns + the three unique indexes, no data
   fixes — a fresh DB has nothing to fix and store sync refills it); one-time
   remediation for pre-existing databases (duplicate pruning with the
   MANUAL-duplicates-fail-loudly rule, failed-terminal slot backfill) ships via the
   uncommitted `scripts/prod-upgrade-store-sync-ssot.sql`. Plus: fetch the iOS build
   number in the three writers that passed NULL (external review, phased-rollout
   mint, production-lead snapshot); `NULLS LAST` on the code-fallback ordering in
   `findMobileVersionRow`. Identity totality is enforced at the two mint sites
   (`insertSyntheticRelease` / `insertExternalReviewRow` skip-and-log when no build
   code resolved; the next sync retries) — deliberately NOT a table CHECK, which
   re-validates on every UPDATE and would break `setPhase`/retire on legacy
   code-less rows. Those heal instead: the external-review update path fills a
   missing code when the observed build provides one (guarded against the identity
   index).
2. **History protection** — `conditionalUpdateTracker` → column-scoped CAS (16e-3).
3. **The SSOT flip** — monitor Incoming chip from the logbook; `review_status` dropped
   from scoreboard reads/writes; delete `findActiveMobileState` / `mirrorProdReview` /
   `setProductionReviewStatus`; `deriveStoreState` shrinks to (rollout, %, track).
4. **Write narrowing** — store-sync's logbook writes become discovery-insert +
   `setPhase`; the iOS phased reflector passes its real `(version, code)` instead of
   clobbering the cell's code to NULL.
5. **Cleanup** — the `phaseFromFields` wf-fallback rows added to mask the overlay lag
   become redundant (row review is now read directly) and can go; dead `StoreCell`
   fields with them.
6. **Android pending-outcome rules** (§16h) — the vanish decision table and the
   guarded snapshot bump. Independent of 1–5; can ship alongside slice 4.

### 16g. Trade-offs (recorded so we don't re-litigate)

- **Rollout mirror kept, review mirror killed.** Rollout: a Play read costs quota and
  SCC knows the value it just set. Review: the production cell holds the LIVE build,
  the review belongs to the INCOMING build — mirroring it there was wrong in kind, not
  just in timing.
- **Pristine snapshot lines may still bump their build number in place** (anti-spam:
  30 TestFlight iterations shouldn't be 30 logbook lines) — but only never-promoted
  `STORE_SYNC` lines, and now guarded against the identity index (today the Android
  same-version-resubmit flow can throw a unique violation mid-sync). Any line that was
  ever promoted keeps its identity forever.
- **One extra monitor query** (Incoming from the logbook) — it already makes it; no
  cost change.
- **The 1% floor stays a single constant** (`androidPendingFractionThreshold`,
  driving pending-inference, adoption, and the scoreboard % alike). This deployment
  parks at ~0.0001% and always ramps at ≥1%, so the sub-1% band is unused by
  convention; a split "parked ceiling" knob was considered and rejected as
  unnecessary. Revisit only if a real <1% ramp step ever becomes practice.

### 16h. Android review blind spots — the vanish rule, the floor split, the guarded bump

Android needs its own rules because of two facts already recorded in §6 and §16b:

1. **There is no "submit for review" on Play.** The only way into Google's review
   queue is to *start* a production rollout — so SCC parks the build at a ~0.0001%
   fraction (a **paper rollout**: paperwork, not exposure).
2. **The API never reports a review verdict.** A parked release looks identical while
   in review and while approved-and-held; a **rejected** release simply **vanishes**
   from the track. The store speaks in track changes, never in verdicts.

Today that produces two real bugs and two traps:

| # | Bug / trap | What the user sees |
|---|---|---|
| 1 | Rejection reads as success: an out-of-band pending release that vanishes is treated as *published* (`ExtComplete`) | a build Google **rejected** shows **"Released · 100%"** (or "Ready to promote" if it still sits on internal) |
| 2 | Zombie on replacement: SCC's parked submission is replaced by a newer out-of-band submission; nothing retires SCC's line | the old line shows **"In review" forever** (and Abort is correctly hidden) |
| 3 | Resubmit-after-rejection can crash the sync: the in-place snapshot bump can move a line onto a `(version, code)` the new MANUAL row already owns → unique violation, and `recordAndroidTracks` isn't inside `safely` | one app's store sync **aborts mid-pass** on the most natural retry flow |

#### 16h-1. The vanish rule (fixes #1 and #2 with one decision)

When a parked submission vanishes, the track *does* tell us what happened — just not
in words. Which release is serving now, and what's pending now, disambiguates all
three outcomes:

```
A parked (version, code) we were watching has VANISHED from the production
track (successful, NON-EMPTY read only — never stamp on missing data):

  serving release's code == our code   → it PUBLISHED  → setPhase Live
  a newer pending code now exists      → it was REPLACED → setPhase Superseded
  neither                              → it was REJECTED or WITHDRAWN
                                         → setPhase (Rejected "left the production
                                           track before publishing")
```

One pure function — `pendingOutcome :: Int32 -> [ProdTrackRelease] -> PendingOutcome`
(`Parked | Published | Replaced | Withdrawn`) — unit-tested like
`detectConsoleRollout`, and applied to **both** work-lists that watch parked codes
(implementation note: the SCC-promoted list classifies against the Play track read
directly; the shared external-review retire path uses its platform-generic twin
`retireOutcome`, which reads the same fact off the just-synced production
*store_status cell* — so the one decision covers iOS vanishes too):

- the external-review reconcile (replacing the blind `ExtComplete`, whose "vanished ⇒
  published" assumption is bug #1), and
- `findMobileAwaitingRollout` rows (SCC-promoted builds), whose detector today does
  *nothing* when our code is gone — bug #2's zombie.

Same rule for both origins — §16b's principle: the model must not care who pressed
the button. Two refinements:

- **Operator-verdict interaction (§6):** the operator's `Approved`/`Rejected` mark
  wins over the *inferred* "pending" state — but a **vanish is a positive track
  signal, not an inference**, so the vanish rule may override an operator mark (e.g.
  marked Approved, then withdrawn in the Console → `Rejected "withdrawn"`). `setPhase`'s
  shadow guard logs the unusual `Approved → Rejected` hop rather than blocking it.
- **Honest wording:** Google rejecting and a human withdrawing the release look
  identical to us. The stamped reason says so ("rejected or withdrawn in Play
  Console"), instead of pretending certainty we don't have.

> **Worked example.** `3.4.1 (402)` parked, Google rejects it → next sync: `402` gone,
> serving is still `(372)`, no newer pending → line stamped **Rejected** (frozen
> history). Team rebuilds as `(403)`, promotes, Google approves, operator publishes →
> serving becomes `(403)` → vanish rule for `403`: `serving == 403` → **Live**; the
> `(372)` line stamps **Superseded**. Every line ends with a true outcome.

#### 16h-2. The guarded bump (fixes #3)

The pristine-snapshot code bump (§16g) gets two guards:

1. Before moving a snapshot line `(version, oldCode) → (version, newCode)`, check no
   `MobileBuild` line already owns `(version, newCode)` (the cross-mode
   `uq_release_tracker_mobile_build` identity). If one does, **skip the bump** — the
   observed build already has its line; there is nothing to record.
2. Wrap `recordAndroidTracks` in the same per-app `safely` isolation as the
   `store_status` writes, so any residual conflict degrades to one logged error
   instead of aborting the app's whole sync pass.

#### 16h-3. Not a bug, but expect the question

Between "SCC sets 10%" and someone clicking **Publish** in the Play Console (managed
publishing), the API keeps reporting the *parked* fraction — so the logbook line says
rolling while the scoreboard truthfully shows the hold, and the store-first read
resolves the display to "held". Deliberate (`androidSnapToUpsert` surfaces the hold
rather than masking it) — operators seeing "why is my 10% not showing?" are looking
at an unpublished release, not a bug.

---

## 17. References

- [`MOBILE_SLOT_SUPERSESSION_AUDIT.md`](./MOBILE_SLOT_SUPERSESSION_AUDIT.md) — the
  cross-version slot defects (bug #4 here closes one of them).
- `backend/src/Products/Autopilot/Mobile/Types.hs` — `MobileBuildContext`,
  `MobileBuildWFStatus`, `claimsStoreIdentity`.
- `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs` — the piecemeal setters
  `setPhase` replaces.
- `backend/src/Products/Autopilot/Mobile/Handlers/Rollout.hs` — the operator
  transitions.
- `backend/src/Products/Autopilot/Mobile/StoreSync.hs` — `observedToPhase` source
  (rollout reconcile + external-review mapping).
- `frontend/src/products/releases/components/mobileStage.ts` — the FE `stageOf`
  precedence `displayStatus` centralises.
