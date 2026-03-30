# Login Page — Design Override

## Layout
- Full page, bg zinc-100 (light gray)
- Centered card: max-w-sm, white, border zinc-200, rounded-xl, shadow-sm
- Logo: centered, h-8, above form
- Title: "System Control Centre" — 16px, Fira Sans 600, zinc-900, centered
- Subtitle: "Sign in to your account" — 13px, zinc-500, centered

## Form
- Email input with label
- Password input with label + show/hide toggle
- "Sign in" button — full width, primary variant, h-10
- Error message: below button, text-red-500, 13px

## Specific Rules
- NO background image, NO gradient, NO decorative elements
- NO "forgot password" link (admin resets via admin panel)
- Loading state: button shows spinner, inputs disabled
- Auto-focus email field on mount
- Enter key submits form
