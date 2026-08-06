# Chime Fleet Campaign + Adoption — design → implementation plan

**Date:** 2026-08-05
**Design sources of truth (pixel authority):**
- `docs/design/mobile-release-summary-mockup-v4.html` — campaign zone placement for the summary page. Review: any page scenario + the "Fleet Campaign (Chime) · OTA rail" toggler, states a–i.
- `docs/design/release-group-detail-mockup-v1.html` — campaign strip in the expanded OTA row + Chime adoption panel. Review: scenario "5. Live" + the "Fleet Campaign (Chime)" toggler.
- API contract: Chime OpenAPI (`openapi.yaml`, servers `appmonitor.moving.tech` / `appmonitor.integ.moving.tech`). Envelope `{status, data}`; errors `{status:"error", reason}`.

The two mockups share **identical campaign markup by construction** — the implementation is ONE
`CampaignCard` component mounted in two places, plus ONE `AdoptionCard` with a `compact` variant.

---

## 0. Scope

In: Chime BFF proxy, `CampaignCard` (9 states), `AdoptionCard` (full + compact), mounts on the
mobile release summary page and the release-group detail OTA row, polling/caching rules.
The Analytics **reads** (`GET /chime/jobs/{id}/funnel`, `GET /chime/versions/users`) are in —
they power the funnel bars and every adoption tile.
Out: the Analytics **writes** (`POST /chime/analytics/funnel`, `POST /chime/analytics/downloaded`)
— device-reported, `X-Event-Key`-authenticated, called by the mobile SDK as the OTA worker runs;
SCC calling them would fabricate device telemetry. Also out: `POST /chime/send/{role}`
(single-person debug push — ops tool, not release UI); daily adoption trend (needs SCC-side
snapshots — optional Phase 5); any native-build coupling (campaigns are OTA-only: the funnel is
the device OTA worker; `airborne_org/app` key every event).

**Hard prerequisite (app-side, NOT SCC):** the read side only shows data if devices report.
Verify the `ny-react-native` OTA worker (airborne/hyper-sdk layer) actually calls the two
analytics POSTs with the `X-Event-Key` (on push received, worker start, downloaded/no_update/
failed). If it doesn't, every campaign ends in state g (`funnel_reported: false`) and adoption
404s — honest UIs, permanently empty. Confirm before Phase 2; if missing, the SDK reporting
integration is its own workstream in the app repo.

---

## 1. Backend — Chime BFF proxy

Follow the `Products/AirborneOta` pattern (server-side key, SCC RBAC in front, browser never
sees the credential).

### 1.1 Config (server_config)
| Key | Meaning |
|---|---|
| `chime_base_url` | e.g. `https://appmonitor.moving.tech` (integ default for debug deployments) |
| `chime_api_key` | sent as `X-API-Key` on every proxied call |

No `X-Event-Key` anywhere in SCC — that credential is device-SDK-only.

### 1.2 Module layout — DECIDED: inside `Products/AirborneOta` (Chime is OTA infrastructure)
```
Products/AirborneOta/Chime.hs   -- typed calls to Chime, envelope decode, error mapping
Products/AirborneOta/Routes.hs  -- new /airborne/chime/... routes appended to AirborneAPI
```
Mounted via the existing `airborneServer` in Core/Server.hs — no new product, no ProductSlug
change. Config keys live beside the airborne ones in server_config.

**Consequence to accept knowingly:** the mobile pages' campaign/adoption UI will call
`/airborne/chime/...`, so operators need an **AirborneOta product grant** (`OTA_*`) in addition
to their mobile grants — unlike the existing mobile OTA panel, which proxies through `/mobile`
routes with `MB_*` perms precisely to avoid that. Mitigation: the FE hides the campaign card and
adoption tiles when the airborne `access` probe says no grant (same graceful degradation as
state i); ops grants `OTA_VIEW` to mobile operators who should see adoption.

### 1.3 Proxied endpoints
| SCC route | Chime call | Perm | Notes |
|---|---|---|---|
| `POST /airborne/chime/campaigns/:appId/launch?dry_run=` | `POST /chime/{role}/{platform}/{package}` | `OTA_RELEASE_RAMP` | role from surface: consumer→`bap`, driver→`bpp`; package = `app_catalog.package_name`. 202 accepted → `{job_id}`; 200 `skipped` passes through as a NORMAL response (not an error) |
| `GET /airborne/chime/jobs?…` | `GET /chime/jobs` | `OTA_VIEW` | pre-launch probe: `status=running&limit=1` filtered to the app's package |
| `GET /airborne/chime/jobs/:jobId/status` | `GET /chime/status/{jobID}` | `OTA_VIEW` | polled while running |
| `GET /airborne/chime/jobs/:jobId/funnel` | `GET /chime/jobs/{jobID}/funnel` | `OTA_VIEW` | the card's main read |
| `POST /airborne/chime/jobs/:jobId/cancel` | `POST /chime/cancel/{jobID}` | `OTA_RELEASE_RAMP` | 200 `cancelling` |
| `GET /airborne/chime/adoption?appId=&tag=` | `GET /chime/versions/users` | `OTA_VIEW` | org from `acAirborneAppRef` (`org~app` → org); version = the bundle **tag**; 404 → `{recorded: false}` (not an HTTP error to the FE) |

Permission choice: launch/cancel reuse **`OTA_RELEASE_RAMP`** — a campaign changes fleet
exposure, the same trust level as ramping; no Permission-ADT surgery needed. If finer grain is
ever wanted, add an `OTA_CAMPAIGN` constructor per the CLAUDE.md new-permission steps.

Error mapping: Chime 503 (+`Retry-After`) → SCC 503 with the header forwarded; Chime 401 →
SCC 502 with reason `chime_key_misconfigured` (FE renders the amber key card, state i).

---

## 2. Frontend — shared components

New folder: `frontend/src/products/releases/components/chime/`
- `CampaignCard.tsx` — the whole strip, all states
- `AdoptionCard.tsx` — `variant: 'panel' | 'compact'`
- `api additions` in `products/releases/api.ts` (`chimeApi.*`), hooks in `hooks.ts`

### 2.1 State machine (mockup toggler ↔ component condition)

| Mockup state | Component condition (from API) |
|---|---|
| a `idle` | no running/completed job for the app AND launch not yet clicked |
| b `dryrun` | last action was launch with `dry_run=true` → show its `users_queried`/`tokens_found` |
| c `running` | job `status === 'running'` |
| d `cancelling` | cancel POST answered `cancelling`, until job reads `cancelled` |
| e `skipped` | launch answered `status:"skipped"` → conflict card + link to the running job |
| f `completed` | job terminal (`completed`) and `funnel_reported === true` |
| g `funnel-pending` | job terminal and `funnel_reported === false` — rates render `—`, NEVER `0` |
| h `error` | job `status === 'error'` |
| i `degraded` | proxy 503 (show last-known + retry w/ `Retry-After`) or `chime_key_misconfigured` (amber key card) |

**c and f are ONE render path** (`camp-running camp-completed` in the mockups): the funnel card,
with running additionally showing the pulse label, `job … · polls every 10s` meta, progress bar
and Cancel; completed swapping in the emerald label + `source: {source} · as of {as_of}` line.
No layout shift at completion.

### 2.2 CampaignCard — pixel spec (copy classes verbatim from the mockups)

Container: `bg-white rounded-lg border border-zinc-200 border-l-4 border-l-violet-400 p-4 flex flex-col gap-3`
(violet accent = OTA identity; the DATA inside is never violet).

Header row: eyebrow `Fleet campaign ·` + status word —
running: `text-violet-600` + `w-2 h-2 bg-violet-500 rounded-full animate-pulse`;
completed: `text-emerald-600`. Right meta `text-[9px] font-mono text-zinc-400`.

Progress row (running only): track `flex-1 h-1.5 bg-zinc-100 rounded-full overflow-hidden`,
fill `bg-violet-500`, width = `(successes+failures)/tokens_found`; `%` label
`text-[10px] font-mono text-zinc-500`; Cancel
`bg-white border border-red-200 text-red-600 font-bold text-[10px] px-3 py-1.5 rounded hover:bg-red-50`.

**Funnel — FINAL agreed styling** (this went through several iterations; this table is the
authority, matching both mockups exactly):

| Row | Label class | Track | Fill | Count class |
|---|---|---|---|---|
| `users_queried` | `w-24 text-zinc-400 font-sans font-medium text-right` | `flex-1 h-4 bg-zinc-50 rounded overflow-hidden` | `bg-zinc-300` | `w-14 text-right text-zinc-700` |
| `sent ok` | `text-zinc-500` (else same) | same | `bg-sky-300` | `text-zinc-700` |
| `fcm_received` | `text-zinc-500` | same | `bg-sky-500` | `text-zinc-700` |
| `worker_started` | `text-zinc-500` | same | `bg-sky-700` | `text-zinc-700` |
| `downloaded` | `text-zinc-500` | same | `bg-emerald-400` | `text-emerald-700 font-bold` |
| `no_update` | `text-zinc-400` | same | `bg-zinc-300` | `text-zinc-500` |
| `failed` | `text-zinc-400` | same | `bg-rose-400` | `text-rose-600` |

Row wrapper `flex items-center gap-2 font-mono text-[10px]`, rows in `flex flex-col gap-1.5`.
Bar widths = value / `users_queried` (the audience is 100%; semantics: sky = in transit,
emerald = landed, zinc = neutral, rose = lost. There is NO `tokens_found` bar — deliberate.)

Rates row (`border-t border-zinc-100 pt-2`): chips
`bg-zinc-50 border border-zinc-200 rounded px-1.5 py-0.5 text-[9px] font-mono text-zinc-500`, in order:
`delivery {rates.delivery}` · `send fail {delivery.failures}` (tooltip: "server-side send failures
(FCM) — distinct from device-side OTA failures") · `reach` · `worker start` · `download` ·
`failure` (`text-red-600`). **Null rate → `—` with the "not measurable yet" note — never 0.**
Right: `{in_flight} in flight (no terminal stage yet)`.

Other states — copy the corresponding mockup card verbatim:
- idle: text + `Dry run` (zinc-bordered) + `Notify fleet` (`bg-violet-600 … hover:bg-violet-700`), footnote "One campaign per app · platform" + "Past campaigns →"
- dryrun: `dry_run` chip + resolved counts + unreachable % + `Launch for real`
- cancelling: amber card (`bg-amber-50 border-amber-200`, hourglass icon) — copy stresses cooperative drain
- skipped: rose card (`bg-rose-50 border-rose-200`, shield icon) + `View running campaign →`
- error: red card + counts at abort + `Relaunch` (safe: updated devices report `no_update`)
- degraded: two stacked cards — zinc 503 card (plugs icon) + amber 401 card (key icon). Chime failure NEVER blocks the release UI.

### 2.3 AdoptionCard — pixel spec

> **REVISED 2026-08-05 during integ testing:** the 2×2 KPI grid is DROPPED. The
> card renders ONLY `versions/users` data — active-users hero + metadata line
> (`v{version} · window · source · as-of`, response-driven fields only). The
> Downloaded/Failure/In-flight tiles duplicated the CampaignCard's funnel and
> mostly rendered "—"; campaign KPIs now live exclusively on the CampaignCard.
> The tile spec below is retained for history only.

`variant='panel'` (group page, `lg:col-span-4` card `p-4 flex flex-col gap-3`):
header eyebrow `Adoption · {window}` + badge
`bg-violet-50 border border-violet-200 text-violet-700 text-[9px] font-bold px-1.5 py-px rounded uppercase`
→ `CHIME · ~APPROX` (title: "HyperLogLog estimates (~1% error at scale)").
KPI tiles **2×2** (`grid grid-cols-2 gap-2`), tile `bg-zinc-50 border border-zinc-100 rounded p-2`,
label `text-[9px] text-zinc-400 uppercase`, value `font-mono font-bold text-sm`:
| Tile | Source | Note |
|---|---|---|
| Active users | `versions/users.active_users` | render with `~` prefix (approximate) |
| Downloaded | latest campaign `funnel.downloaded` | |
| Failure rate | `rates.failure` | `text-emerald-600` when healthy |
| In flight | `in_flight` | |
Footer pinned `mt-auto … border-t pt-2`:
`window: {window_hours→"168h"} · source: {source} (flushes to Postgres after) · counts ~1%`.
**No daily bars** — Chime has no time series (`versions/users` is point-in-time HLL over a rolling
window; funnels are cumulative). Empty state (adoption 404): dashed
`border-dashed border-zinc-200/300 rounded … text-[10px] text-zinc-400` — "No adoption recorded …
A fleet campaign accelerates this."

`variant='compact'` (summary OTA rail, replaces the old "Connect Mixpanel" block): same 2×2 tiles
at `p-1.5 / text-xs / text-[8px]` scale — copy the rail block from the summary mockup.

**Labels computed from responses, not hardcoded:** `window_hours` → "7 days"/"168h", `source`,
`as_of`. Only "~1%" is static (spec-documented HLL characteristic).

### 2.4 Mount points

Summary page (`MobileReleaseSummary.tsx`): `CampaignCard` as a **full-width zone between the tab
bar and the two-column grid** (mockup: section `mb-6`, eyebrow "Fleet Campaign · OTA bundle").
Render only when the release has an OTA release (`OtaFlow`'s data says so). `AdoptionCard
compact` inside the ongoing-OTA card where the Mixpanel placeholder was.

Group page (`OtaSection` / group detail expanded row): `CampaignCard` full-width **below** the
three panels. The three panels are now **equal `lg:col-span-4`** (was 4/3/5) — Job Matrix gains a
column; `AdoptionCard panel` is the third. OTA section container: the `border-l-[6px]
border-l-violet-500` rail was REMOVED (`bg-white rounded-xl border border-zinc-200 …` only).

### 2.5 Hooks / polling
- `useChimeCampaign(appId)`: resolves current job (`jobs?package=…&limit=1`), then polls
  `status` every **10s only while `running` or `cancelling`**; stops on terminal. Funnel fetched
  on card mount and after terminal transition.
- `useChimeAdoption(appId, tag)`: on mount, cached (react-query), no polling; 404 → empty state.
- Launch/cancel: plain mutations; `skipped` resolves the success path (rose card), never a toast error.
- Degraded: 503 keeps last-known data on screen (`isError` styling, state i), honours `Retry-After`.

---

## 3. Phases

| Phase | Deliverable | Depends on |
|---|---|---|
| 1 | **DONE 2026-08-05.** BFF proxy (`SC_CHIME_URL` Config + `SC_CHIME_API_KEY` secret, `AirborneOta/Chime.hs`, six `/airborne/chime/:app/...` routes app-scoped via `resolveApp`+`requireOtaPermission`, adoption 404→`{recorded:false}`, `chime.configured` folded into `/airborne/health`) + `chimeApi` + wire types in api.ts. Note: routes are `:app`-ref-scoped (org derived server-side), not `:appId` as first sketched. | Chime key provisioned (`SC_CHIME_URL`/`SC_CHIME_API_KEY` env) |
| 2 | **DONE 2026-08-05.** `components/chime/CampaignCard.tsx` — all 9 states (running/terminal share one funnel card; cancelled renders as a zinc-labeled terminal; funnel-pending is the dashed block inside it; degraded splits key-missing vs unreachable off the error text). Self-gates via `useOtaAccess` (null without OTA_VIEW; actions need OTA_RELEASE_RAMP). Polling: jobs+status 10s / funnel 15s only while running. Mounted in `MobileReleaseSummary` between tabs and grid, gated on `otaCapable` + `packageName`. | 1 |
| 3 | **DONE 2026-08-05.** Group-page mount: `CampaignCard` in `OtaSection`'s expanded row below `OtaLifecyclePanel`, catalog matched by `airborneAppRef` (exact — `useMobileApps`, no name heuristics), role from `surface`. OTA section's violet left rail removed. The 4/4/4 panel rebalance moves to Phase 4 — its third panel IS the AdoptionCard. | 2 |
| 4 | **DONE 2026-08-05.** `components/chime/AdoptionCard.tsx` (panel + compact). Group panel: `AdoptionAnalytics` (airborne analytics + Mixpanel badge + daily bars) DELETED → AdoptionCard panel, grid rebalanced 4/4/4. Summary rail: `MetricsBlock` DELETED → compact AdoptionCard on the live release. Version identity = `pkgTagOf(release)` (fallback `pkgVersionOf` as string); campaign KPIs share CampaignCard's query keys (one fetch, CampaignCard owns polling); window/source labels rendered from the response. Dead `fetchOtaAdoption`/`fetchOtaFailures` imports pruned. | 1 |
| 5 (optional) | `chime_adoption_snapshot` table + daily sample of `versions/users` per live bundle → real single-series trend where the removed fake bars were | 4 |

## 4. Open decisions (small, pre-Phase-1)
1. ~~Module home~~ **DECIDED 2026-08-05: `Products/AirborneOta` (Chime is part of OTA)** — see §1.2, including the cross-product permission consequence.
2. `Retry-After` handling in `Core.Http.Client` (respect vs fixed backoff).
3. Rename the OTA "Revert to…" verb to "Revert to stable" (it reverts to exactly one target; the ellipsis over-promises). One word in `OtaLifecyclePanel.tsx:706` + both mockups — approved separately.

## 5. Invariants (do not lose these in implementation)
- One campaign per (role, platform, package) — `skipped` is a normal outcome; render the conflict card, don't toast an error.
- `ignored`/null-rate semantics: `—` means "not measurable yet", never zero.
- Campaigns are OTA-scoped; never render campaign UI next to store-rollout controls.
- Chime unavailability never blocks release operations.
- Color grammar in the card: sky = in transit, emerald = landed, zinc = neutral, rose = lost, violet = OTA chrome only.
