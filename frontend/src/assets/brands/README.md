# Brand logos

Drop a logo here named by its **brand slug** and the App Release Monitor picks it up
automatically — `BrandLogo` (`src/products/releases/components/BrandLogo.tsx`)
auto-discovers this folder via a Vite glob, so **no code change** is needed.

- **Slug** = brand name, lowercased, with every run of non-alphanumeric chars collapsed
  to a single `-` (e.g. `Namma Yatri` → `namma-yatri`, `Kerala Savaari` → `kerala-savaari`).
- Brands without a file (or whose image fails to load) fall back to a colored initials
  monogram, so the UI always renders something.
- Extensions: `.svg` (preferred), `.png`, `.webp`, `.jpg`.
- Use a **square, transparent-background** icon (~64–256 px) for the cleanest result.

## Current brands → expected filename

| Brand          | File                 |
| -------------- | -------------------- |
| Bharat Taxi    | `bharat-taxi.svg`    |
| Bridge         | `bridge.svg`         |
| Cumta          | `cumta.svg`          |
| Kerala Savaari | `kerala-savaari.svg` |
| Lynx           | `lynx.svg`           |
| Mana Yatri     | `mana-yatri.svg`     |
| Maruti Suzuki  | `maruti-suzuki.svg`  |
| Namma Yatri    | `namma-yatri.svg`    |
| Odisha Yatri   | `odisha-yatri.svg`   |
| Yatri          | `yatri.svg`          |
| Yatri Sathi    | `yatri-sathi.svg`    |
