# Release Summary Page — Design Override

## Layout
- **Header section:**
  - Breadcrumb: Releases > {cluster} > {release-id} (Fira Code for ID)
  - Status badge (large, with dot)
  - Action buttons row (right-aligned):
    - Approve (success variant) — shown when CREATED + not approved
    - Discard (ghost) — shown when CREATED
    - Pause/Resume (secondary) — shown when INPROGRESS/PAUSED
    - Abort (danger) — shown when INPROGRESS/PAUSED
    - Revert (secondary) — shown when COMPLETED
    - Clone (ghost, always visible)
    - All behind PermissionGate with appropriate permission
  - Confirmation dialog before destructive actions (abort, revert, discard)

- **Tabs** (custom underline style, 4 tabs):
  - `Summary` | `Events` | `ENV Diff` | `JSON Data`
  - Implemented as plain buttons with bottom border on active (`border-zinc-900`), not Radix.
  - **Note:** Rollout History is NOT a standalone tab. It is rendered inline inside the Summary tab (after Pod Health, before the editable Rollout Strategy block).

- **Summary tab** (the busy one — many sub-sections, all inline):
  - Three-column grid of info cards at top: `TIME SCHEDULE` (created/scheduled/last-updated/start/end), `META DATA` (priority/env/mode/approval), `K8S INFO` (release ID/cluster/category/strategy summary/global ID).
  - **Pod Health + Deployment Status** section (table of pods with health/status).
  - **Rollout History** (inline section, not a tab): table with Start | Rollout % | End | Decision | HS Decision | Manual | Cooloff | Pods. Decision column uses colored text (Continue=emerald, Abort=red, Wait=amber).
  - **Rollout Strategy** (inline, editable when permitted): Stage | Rollout % | Cooloff (min) | Pods.
  - **Release Details** card at the bottom: App Group, Service, Old/New Version, Docker Image, Release Manager, Infra Approved, Description, Change Log, Global ID. Technical fields (versions, image, IDs) in Fira Code.

- **Events tab:**
  - Table of release events fetched via `useReleaseEvents`.
  - Columns: Timestamp (mono), Category (badge), Label, Value (truncated).
  - Expanded row: formatted JSON in `<pre>`, monospace, bg zinc-50.
  - Search input to filter events.
  - Category badges: Business=blue, Decision=purple, Notification=green.

- **ENV Diff tab:**
  - Renders the diff between previous and new environment configuration for the release (`EnvDiffTab` component, fetches by release ID).
  - Used to review env-override changes before/after a release.

- **JSON Data tab:**
  - Raw JSON dump of the full release object inside a `<pre>` block.
  - Background zinc-50, border zinc-200, monospace, max-height ~600px with scroll, `whitespace-pre-wrap` for wrapping.

## Specific Rules
- Auto-refresh every 10s
- Action buttons show loading spinner during API call
- Toast on action success/error
- Status badge updates in real-time
