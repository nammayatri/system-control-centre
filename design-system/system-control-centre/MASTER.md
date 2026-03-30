# Design System Master File — System Control Centre

> **LOGIC:** When building a specific page, first check `design-system/pages/[page-name].md`.
> If that file exists, its rules **override** this Master file.
> If not, strictly follow the rules below.

---

**Project:** System Control Centre
**Category:** Internal Engineering Dashboard (DevOps Operations Tool)
**Aesthetic:** Clean, professional, data-dense. Think Linear, GitHub, Datadog — not a marketing site.

---

## Design Philosophy

This is an **internal tool used by engineers 8 hours a day**. Every decision optimizes for:
1. **Scannability** — find information fast in dense tables
2. **Clarity** — status at a glance, no ambiguity
3. **Efficiency** — minimum clicks to complete a task
4. **Trust** — looks professional, not like a hackathon project

**NEVER use:** Gradients, glassmorphism, blur effects, glowing accents, decorative shapes, fancy animations, parallax, rounded blobs, or anything that looks "made by AI."

---

## Color Palette

| Role | Hex | Usage |
|------|-----|-------|
| Sidebar BG | `#0a0a0a` | Sidebar background — near-black |
| Sidebar Hover | `#171717` | Sidebar item hover |
| Sidebar Active | `#262626` | Active nav item bg |
| Sidebar Text | `#a1a1aa` | Inactive nav text (zinc-400) |
| Sidebar Text Active | `#fafafa` | Active nav text |
| Accent | `#3b82f6` | Active indicator, links (blue-500) |
| Content BG | `#fafafa` | Main content area |
| Card BG | `#ffffff` | Cards, tables |
| Border | `#e4e4e7` | Card borders, dividers (zinc-200) |
| Border Light | `#f4f4f5` | Table row borders (zinc-100) |
| Text Primary | `#18181b` | Headings, primary text (zinc-900) |
| Text Secondary | `#52525b` | Descriptions, labels (zinc-600) |
| Text Muted | `#a1a1aa` | Timestamps, metadata (zinc-400) |
| Success | `#22c55e` | Completed, approved (green-500) |
| Warning | `#f59e0b` | In progress, pending (amber-500) |
| Danger | `#ef4444` | Aborted, failed, errors (red-500) |
| Info | `#3b82f6` | Created, informational (blue-500) |
| Paused | `#6366f1` | Paused state (indigo-500) |
| Muted | `#71717a` | Discarded, inactive (zinc-500) |
| Purple | `#8b5cf6` | Reverting, special states (violet-500) |

**No purple backgrounds. No orange CTAs. No excitement colors. This is an operations tool.**

---

## Typography

| Role | Font | Weight | Size |
|------|------|--------|------|
| UI Text | Fira Sans | 400, 500, 600 | 13-14px body |
| Technical Data | Fira Code | 400, 500 | 12-13px (IDs, versions, timestamps, code) |
| Page Titles | Fira Sans | 600 | 18-20px |
| Section Titles | Fira Sans | 600 | 14-15px |
| Table Headers | Fira Sans | 500 | 12px uppercase tracking-wider |
| Badges | Fira Sans | 500 | 10-11px uppercase |

```css
@import url('https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&family=Fira+Sans:wght@400;500;600;700&display=swap');
```

**Rules:**
- Body text: 14px, line-height 1.5
- Max line length: 75 characters
- Monospace (Fira Code) for: release IDs, version numbers, timestamps, cluster names, JSON, YAML, config values
- Sans (Fira Sans) for: labels, headings, descriptions, button text, navigation

---

## Component Specs

### Buttons
- Height: 32px (sm), 36px (md), 40px (lg)
- Border radius: 8px
- Font: 13px Fira Sans, weight 500
- Transitions: background-color 150ms
- **NO transform/scale on hover** — only color change
- Primary: bg zinc-900, text white, hover zinc-800
- Secondary: bg white, border zinc-300, text zinc-700, hover bg zinc-50
- Danger: bg red-600, text white, hover red-700
- Ghost: transparent, text zinc-600, hover bg zinc-100
- **Always** disable during async operations (show spinner)

### Cards
- Border: 1px solid zinc-200
- Border radius: 12px
- Background: white
- Shadow: **none or shadow-sm only** (0 1px 2px rgba(0,0,0,0.05))
- **NO hover elevation/transform** — cards don't float
- Header: border-bottom zinc-100, padding 16px 20px
- Content: padding 16px 20px

### Tables
- Header: bg zinc-50, text zinc-500, font 12px uppercase tracking-wider
- Rows: alternating white / zinc-50, hover bg zinc-100
- Border: bottom border zinc-100 between rows
- Cell padding: 12px 16px
- Technical data (IDs, versions) in Fira Code
- Status: dot indicator (6px circle) + uppercase text
- Actions column: icon buttons, right-aligned
- **Wrap in overflow-x-auto** for mobile

### Inputs
- Height: 36px
- Border: 1px solid zinc-300
- Border radius: 8px
- Font: 14px
- Focus: ring-2 ring-zinc-400 (not colored ring — neutral)
- Label: 11px uppercase tracking-wider zinc-600, above input
- Error: border-red-400, error text below in red 12px
- Disabled: bg zinc-50, text zinc-500

### Dialogs/Modals
- Overlay: bg black/40 (no blur — simple dim)
- Card: white, rounded-xl, shadow-xl
- Max-width: 480px (sm), 640px (lg)
- Close button: top-right, zinc-400, hover zinc-600
- z-index: 50

### Badges/Status
- Small: px-2 py-0.5, text 10px, uppercase, rounded-md
- Border: 1px solid (color-matched)
- Dot: 6px circle, left of text
- Background: very light tint of status color (e.g., emerald-50 for success)
- Text: darker shade (e.g., emerald-700 for success)
- **NO full-color background badges** — use tinted backgrounds

### Sidebar
- Width: 260px (expanded), 60px (collapsed)
- Background: #0a0a0a
- Navigation items: 40px height, 13px font
- Active state: bg #262626, left border 2px blue-500 or emerald-500
- Sections: collapsible with chevron, 12px uppercase label
- Logo area: h-14, border-bottom zinc-800
- User area: bottom, avatar + name + email
- Collapse toggle: bottom-most element

### TopBar
- Height: 56px
- Background: white
- Border: bottom 1px zinc-200
- Left: breadcrumb trail (zinc-500 text, / separator)
- Right: user avatar dropdown

---

## Spacing Scale

| Token | Value | Usage |
|-------|-------|-------|
| 1 | 4px | Tight inline gaps |
| 2 | 8px | Icon-text gaps, badge padding |
| 3 | 12px | Table cell padding, compact spacing |
| 4 | 16px | Standard padding, card content |
| 5 | 20px | Card header/content padding |
| 6 | 24px | Section gaps |
| 8 | 32px | Page padding |
| 12 | 48px | Large section gaps |

---

## Interaction Rules

1. **cursor-pointer** on ALL clickable elements (buttons, links, table rows, toggle buttons)
2. **Hover: background-color only** — no transform, no scale, no elevation
3. **Transition: 150ms** for hover states, 200ms for expand/collapse
4. **Focus: ring-2 ring-zinc-400 ring-offset-1** — visible, neutral, consistent
5. **Disabled: opacity-50, pointer-events-none**
6. **Loading: spinner in button, skeleton for content, never blank screen**
7. **prefers-reduced-motion: skip all transitions**
8. **Touch targets: minimum 44x44px** on mobile
9. **Tab order matches visual order** — no tabIndex hacks
10. **Toast notifications: top-right, auto-dismiss 4s, close button**

---

## Anti-Patterns (FORBIDDEN)

- Gradients of any kind
- Glassmorphism / backdrop-blur
- Glowing effects / neon accents / text shadows
- Rounded blobs / decorative shapes
- Scale/elevation on hover (translateY, scale)
- Parallax scrolling
- Custom cursors
- Background patterns/textures
- Animated backgrounds
- Purple/orange "excitement" color schemes
- Drop shadows larger than shadow-sm on cards
- Emojis as icons
- Auto-playing animations
- Any element that makes someone say "that looks AI-generated"

---

## Pre-Delivery Checklist

- [ ] No gradients, glassmorphism, or decorative effects
- [ ] No emojis as icons — Lucide SVG icons only
- [ ] cursor-pointer on all clickable elements
- [ ] Hover states: background-color change only (150ms transition)
- [ ] Focus states: ring-2 ring-zinc-400 visible on all interactive elements
- [ ] Text contrast 4.5:1 minimum (zinc-900 on white = 15.4:1 ✓)
- [ ] Buttons disabled during async operations
- [ ] Skeleton loaders for data, not blank screens
- [ ] Tables wrapped in overflow-x-auto
- [ ] Fira Code for technical data (IDs, versions, timestamps)
- [ ] Fira Sans for UI text (labels, headings, buttons)
- [ ] Responsive: sidebar collapses, tables scroll, forms stack
- [ ] prefers-reduced-motion respected
- [ ] Tab order matches visual order
