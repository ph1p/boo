# Boo Styleguide

How Boo's chrome looks and which control to reach for. Boo themes its whole UI
from the terminal theme, so no view should hard-code a colour or use a stock
AppKit/SwiftUI control that paints with the system accent.

Code lives in three places:

| What | Where |
| --- | --- |
| Colour tokens | `TerminalTheme` (`Boo/Models/Theme.swift`), mirrored for SwiftUI by `Tokens` (`Boo/Views/Settings/SettingsTokens.swift`) |
| Metrics (spacing, radii, heights, type) | `BooStyle` (`Boo/Views/BooStyle.swift`) |
| Controls | `Boo/Views/ThemedControls.swift`, `Boo/Views/ThemedPickers.swift` |

## Colour

Read colours from `@Environment(\.tokens) private var t`. Never read
`Tokens.current` from a leaf view's `body`, because it does not update when the
theme changes. In AppKit, use the `TerminalTheme` property with the same name.

Base colours come from the theme: `text` (chromeText), `muted` (chromeMuted),
`accent`, `bg` (sidebarBg), `chromeBg`, `termBg` and `fg`.

Derived tokens. Use these instead of `muted.opacity(…)`, so the alphas stay the
same across the app:

| Token | Value | Use |
| --- | --- | --- |
| `textSecondary` | muted 70 % | Secondary text, glyphs |
| `textTertiary` | muted 50 % | Placeholders, idle icons |
| `separator` | muted 20 % | Hairlines, field borders. Only for draws that cannot overlap themselves |
| `subtleFill` | muted 6 % | Text-field fill, hovered segment |
| `hoverFill` | muted 10 % | Row hover, idle control fill, segment track |
| `controlFill` | muted 15 % | Hovered control fill |
| `cardBg` | muted 12 % blended over sidebarBg (opaque) | Cards, raised segment thumb |
| `accentSelectionFill` | accent 15 % | Selected row |
| `accentEmphasis` | accent 85 % | Pressed/active accent fills |
| `focusRing` | accent 70 % | Focused field border |
| `success` `warning` `error` `info` | theme | Status only, never decoration |

Rules:

- Do not put a translucent stroke over a translucent fill. The two alphas stack
  into a dark ring. Controls use fill only. Fields are the exception: they draw
  a hairline over the very light `subtleFill`.
- Text on `accent` is white. Everything else uses `text`, `textSecondary` or
  `textTertiary`.
- Use `warning` for "needs you" states, such as an agent waiting for input.

## Metrics

Pick the nearest step instead of a one-off number.

- **Space** (`BooStyle.Space`): 2 · 4 · 6 · 8 · 12 · 16 · 24 (`xxs` to `xxl`).
- **Radius** (`BooStyle.Radius`, always `.continuous`):
  - `tiny` 3.5: checkboxes and badges.
  - `control` 6: buttons, fields and pickers.
  - `large` 8: large calls to action.
  - `card` 10: cards and inline forms.
- **Height** (`BooStyle.Height`):
  - `control` 24 for buttons, fields and pickers, so one row lines up.
  - `large` 32 for full-width calls to action.
- **Type** (`BooStyle.Font`):
  - `body` 12: field text.
  - `control` 11 medium: button and picker labels.
  - `caption` 11: help text.
  - `sectionTitle` 11 semibold.
- Sidebar content follows the user's sidebar font. In the sidebar, use
  `fontScale.font(.xs / .sm / .base)` instead of `BooStyle.Font`.

## Controls

| Need | Use | Notes |
| --- | --- | --- |
| Action | `.buttonStyle(.themed(variant, size:))` | Variants: `.primary` (accent, one per view), `.secondary` (default), `.subtle` (toolbar-like), `.destructive`. Sizes: `.small` (24pt) and `.large` (32pt, full width) |
| Icon-only action | `SidebarIconButton` (sidebar) / `IconButton` (settings) | Always pass `help:` |
| Text input | `SettingTextField` / `.themedFieldChrome(focused:)` | `subtleFill` fill, separator hairline, `focusRing` and an accent halo when focused |
| 2–4 short exclusive options | `ThemedSegmentedPicker` | The selected option sits on a raised `cardBg` thumb. Do not use it for options that can grow |
| Longer or dynamic list | `ThemedMenuPicker` | Opens a native `NSMenu`. Use `itemFont:` to show font faces and `width:` for a fixed width |
| Font family / size | `FontChooser` / `FontSizePicker` | Built on `ThemedMenuPicker` |
| On/off setting | `.toggleStyle(.themedSwitch)` (via `ToggleRow`) | Takes effect immediately |
| Option inside a sentence or form | `.toggleStyle(.themedCheckbox)` | For example "Shorten pauses" next to a value |
| Bounded number | `ThemedStepper(value:in:step:format:)` | `format` renders the unit ("30 days", "Forever") |

Do not use `.pickerStyle(.segmented/.menu)`, `NSPopUpButton`, `Stepper` or
`.toggleStyle(.switch)` in Boo chrome. System alerts are fine as they are,
for example the `TextField` inside an `.alert`.

## Sidebar patterns

- **Section header** (`SidebarSectionHeaderView`, AppKit): an uppercase title
  with a count, collapsible.
- **Section separator**: `SidebarLayout.separatorHeight` (9pt) is a band with a
  centred 1pt `separator` hairline. This gives both headers room to breathe. The
  drag handle centres on the same line.
- **List header** (like `FileTreeNavigationBar` or the Agents crew header):
  - A muted `.xs` summary sits on the left. Example: "3 running · 1 needs you",
    with the attention part in `warning`.
  - A `SidebarIconButton` with the primary action sits on the right.
  - Show it only when the list has items.
- **Empty state**: a centred icon, a title and one sentence of help, then a
  `.themed(.primary, size: .large)` button. The large button appears only here.
  Once items exist, the action moves to the list header's "+".
- **Stable order**: never reorder a list because focus or the active workspace
  changed. Group by a stable key, such as workspace-bar order, and mark the
  active group instead of moving it.

## Settings patterns

- Build a page as `SettingsPage`, then `Section(title:footer:)` cards, then a
  `SettingRow` (label left, control trailing) or a `SettingStack` (control
  below the label, for wide controls).
- `Tokens.labelWidth` is 112, `rowSpacing` is 10 and `sectionPadding` is 12.
- Put help under the row as `caption` in `textSecondary`. Keep it to one or
  two sentences.
- To check pages visually, run
  `BOO_SNAPSHOT_DIR=/some/dir swift test --filter SettingsSnapshotTests`. It
  writes one PNG per page.
