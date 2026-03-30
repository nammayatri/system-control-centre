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

- **Tabs** (Radix Tabs, underline style):
  - Summary | Rollout History | Events

- **Summary tab:**
  - Two-column grid of info cards
  - Left card "Release Info": Service, Product, Env, Mode, Version (old→new), Docker Image, Tracker Type
  - Right card "Timeline": Created, Start Time, End Time, Schedule Time, Release Manager
  - Bottom card "Details": Description, Change Log, Info (full-width, expandable if long)
  - All technical values in Fira Code

- **Rollout History tab:**
  - Strategy table: Stage | Rollout % | Cooloff (min) | Pods
  - History table: Start | Rollout % | End | Decision | HS Decision | Manual | Cooloff | Pods
  - Decision column: colored text (Continue=emerald, Abort=red, Wait=amber)

- **Events tab:**
  - Expandable rows table
  - Columns: Timestamp (mono), Category (badge), Label, Value (truncated)
  - Expanded: formatted JSON in pre block, monospace, bg zinc-50
  - Search input to filter events
  - Category badges: Business=blue, Decision=purple, Notification=green

## Specific Rules
- Auto-refresh every 10s
- Action buttons show loading spinner during API call
- Toast on action success/error
- Status badge updates in real-time
