# Release List Page — Design Override

## Layout
- **KPI strip** at top: 4 cards in a row (Total, Active, Completed Today, Failed Today)
  - Cards: h-20, border zinc-200, no shadow
  - Number: 24px Fira Sans bold, zinc-900
  - Label: 11px uppercase zinc-500
  - Indicator: small colored dot next to number matching status

- **Toolbar** below KPI strip:
  - Search input (left, w-64, Lucide Search icon)
  - Status filter dropdown (Select component)
  - Product filter dropdown
  - Date range picker (Popover with presets)
  - Refresh button (icon-only, ghost variant)
  - "Create Release" button (right-aligned, primary, behind PermissionGate)

- **Table** fills remaining height:
  - Columns: S.No, Service, Release ID (mono), Version (mono), Status, Created, Actions
  - Release ID: truncated to 12 chars with tooltip showing full ID, click copies
  - Version: Fira Code, zinc-700
  - Status: dot + uppercase text badge
  - Created: relative time ("2h ago") with tooltip showing full timestamp
  - Actions: Copy/Clone icon button
  - Row click → navigates to release summary

- **Pagination** at bottom:
  - Left: "Showing 1-10 of 234 releases"
  - Right: Page size selector (10/25/50) + Previous/Next buttons

## Specific Rules
- Auto-refresh every 60s via React Query `refetchInterval: 60000` in `useReleases` hook
- Search debounced 300ms
- Default date range: `today` (from midnight to now)
- Empty state: centered text "No releases found" with muted icon
