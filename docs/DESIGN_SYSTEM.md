# Design System

ClipHelm is a native macOS tool for creators. The interface uses system controls, SF Pro, SF Symbols, and a follows-macOS appearance. On top of that it adds one brand accent and a small set of shared components. Tokens and components live in `Sources/ClipHelmApp/DesignSystem.swift`. Views use them and don't hard-code spacing, radii, colors, or status text.

## Principles

1. **One primary action per screen.** Home: New Clip Project. Wizard: Continue / Create Project in the pinned footer. Workspace: the circular Start button. Review sheet: Save Changes.
2. **Status is never color alone.** Every state pairs an SF Symbol with text (`StatusMessage`, `StatusBadge`).
3. **Show, don't name.** Visual choices (canvas, framing, pacing, caption style) are picked from cards with an icon, a description, or a rendered sample.
4. **Explain disabled actions.** When a forward action is unavailable, the reason appears next to it (for example, "Choose a video to continue.").
5. **Respect the platform.** Native pickers, forms, sheets, and keyboard shortcuts. Reduce Motion turns off step and drop-zone transitions.

## Tokens

| Token | Values |
|---|---|
| `DS.Space` | 4 · 8 · 12 · 16 · 24 · 32 · 48 pt |
| `DS.Radius` | small 6 · medium 10 (cards, controls) · large 14 (surfaces, video) |
| `DS.Width` | form 720 (wizard, settings) · content 1080 (workspace) |
| `DS.Motion` | quick 0.18 s snappy (selection) · standard 0.25 s smooth (step change) |
| `DS.accent` | the logo's blue: light `#1E66D8`, dark `#2F6FE4`; white labels on either meet 4.5:1 (5.3:1 and 4.65:1) |
| `DS.brandGradient` | the logo's teal `#7FEDD4` to blue `#326FE6`; brand moments only, never text |
| `DS.surface` | `controlBackgroundColor`, with a hairline `primary @ 10%` stroke |
| `DS.videoBackground` | black, for players and thumbnails |

The accent is applied once at the window root with `.tint(DS.accent)`. Semantic tones (`StatusTone`) use system blue, green, orange, and red so they adapt to both appearances and to Increase Contrast.

## Components

| Component | Use |
|---|---|
| `surfaceCard(padding:highlighted:)` | Groups one task or topic. `highlighted` marks the ready or primary card. |
| `readableColumn(_:padding:)` | Centers detail content at a readable maximum width. |
| `PageHeader` / `Eyebrow` | Title block for every route: optional eyebrow, large title, subtitle, trailing accessory. |
| `StatusMessage` | Inline icon + text feedback. Tones: neutral, info, success, warning, error. |
| `StatusBadge` | Compact state capsule for a stage or project ("Running", "Done", "3 clips saved"). |
| `TaskProgressRow` | The single progress pattern: bar or spinner, stage text, percent, Cancel. |
| `OptionCard` / `OptionCardGrid` | Single-select (radio indicator) or multi-select (`multiple: true`, checkbox indicator) choice cards. |
| `UniformGrid` | Card grid where every cell shares one width and the tallest cell's height, and columns never outnumber cells. Use it for any group of peer cards so they line up. |
| `AppLogo` | The bundled app icon (Home hero, About, empty Recent Projects). Draws nothing in unbundled runs. |
| `ToggleRow` | Switch with icon and description, for independent options. |
| `StageCard` | Workspace stage with icon, title, status badge, header actions, and body. |
| `CaptionStyleSwatch` / `CaptionStyleCard` | Static sample of each caption style. Colors and fonts mirror `CaptionRenderer`'s presets and must be kept in sync. |

## Screen structure

- **Sidebar**: logo and wordmark, then **New Clip Project** as a full-width primary button (an action, not a destination). Below that, a Library section (Home, and Recent Projects with a count badge) and a Projects section listing the eight most recent projects. Each project row shows a gradient tile, its status, and a relative date so same-named projects stay distinct. Settings is pinned to the bottom with its shortcut.
- **Home**: hero surface with the primary action, a three-step "how it works" row, and recent projects as one grouped list.
- **New Clip Project**: header, clickable step rail (completed steps jump back), step content, and a pinned footer with Back, the blocking reason, and Continue. The Review step lists every choice with an Edit link to its step.
- **Workspace**: the clip job card first. Before a run it holds the circular **Start** button, the live download line, and a summary of the chosen options; during a run it lists every phase with its state and percent; afterwards it summarizes the result. Generated clips follow, then the player (a taller stage for vertical sources), the source-access card when needed, and an optional "Explore the source" group: Local analysis, Transcript, Best moments.
- **Generated clips**: adaptive grid of cards with thumbnails in the output's aspect ratio, a duration badge, a selection checkbox, and Edit, Export, and More actions. The header switches between Select All and "N selected · Deselect All".
- **Review Clip sheet**: vertical clips sit beside the controls, horizontal clips above them. A pinned footer holds Delete, Export, and Save Changes (⌘S). Closing with unsaved changes asks before discarding.
- **Settings**: grouped surfaces for General, OpenRouter, and Keyboard Shortcuts.

## App icon

The icon source is `Resources/ClipHelm.icon`, an Icon Composer file with light and dark fills and glass layers. `scripts/build-app.sh` compiles it with `actool` into `Assets.car` plus a `ClipHelm.icns` fallback for macOS versions before 26, and `Info.plist` names it through `CFBundleIconName` and `CFBundleIconFile`. Edit the icon in Icon Composer and replace the whole `.icon` folder; don't edit the exported PNGs.

## Checklist for new UI

- [ ] Uses `DS` tokens; no raw hex, ad hoc padding, or corner radii.
- [ ] Status and errors use `StatusMessage` / `StatusBadge` (icon + text).
- [ ] Long tasks use `TaskProgressRow` with Cancel.
- [ ] Icon-only controls have an accessibility label and a `.help` tooltip.
- [ ] Selected cards expose `.isSelected`; headers expose `.isHeader`.
- [ ] Animations check `accessibilityReduceMotion`.
- [ ] Lays out at the 780 × 560 minimum window and in both appearances.
