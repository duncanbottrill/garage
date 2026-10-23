# Design

Mews visual system. Source of truth for values is `packages/tokens/tokens.json`, generated into `Tokens.swift` for the Apple apps. Figma: file DataTes, direction "D4 / Hybrid".

## Theme

Dark only. The scene is a car's dashboard at night: a near-black ground with a faint blue cast, one cool accent, and status colours that appear only when true. Surfaces are flat; "glass" is a single elevated surface at 86–90% opacity with a 24pt blur, used for sheets and the dock, not decoratively. Hairlines at 8% ink separate regions instead of borders.

## Color

| Token | Value | Use |
|---|---|---|
| background | #0B0F14 | App ground |
| mapGround | #0D1218 | Map canvas |
| roadMinor | #19212A | Map minor roads |
| roadMajor | #233040 | Map major roads |
| water | #0A1A26 | Map water |
| glass | #0F151C | Sheets, dock, elevated tiles |
| ink | #EAF0F6 | Primary text and glyphs |
| muted | #7D8A99 | Secondary text, labels |
| accent | #4FE3FF | Live state, primary action, selection |
| charging | #3DDC97 | Charging state only |
| warning | #FFB020 | Attention state only |
| danger | #F26D6D | Fault or destructive only |

Opacity tokens: glass 0.86, glassStrong 0.90, hairline 0.08, accentFill 0.14, accentStroke 0.50. Accent surfaces are accent at 14% fill with a 50% stroke, never a solid cyan block. No gradients on text or controls.

Color strategy: restrained. One accent at under 10% of any screen.

## Typography

- **Big Shoulders Display** (variable, wght 600 default) for numerals and display: the number is the headline.
- **Instrument Sans** (variable wdth/wght; 400 body, 500 titles and labels) for everything else.

| Style | Family | Size | Line | Tracking |
|---|---|---|---|---|
| numeralHero | Big Shoulders 600 | 84 | 0.84 | -0.02em |
| numeralL | Big Shoulders 600 | 34 | 0.9 | 0 |
| numeralM | Big Shoulders 600 | 30 | 1.0 | 0 |
| numeralS | Big Shoulders 600 | 22 | 0.9 | 0 |
| title | Instrument Sans 500 | 17 | 1.3 | 0 |
| body | Instrument Sans 400 | 14 | 1.4 | 0 |
| caption | Instrument Sans 400 | 12 | 1.3 | 0 |
| label | Instrument Sans 500 | 11 | 1.3 | 0.12em |
| labelS | Instrument Sans 500 | 10 | 1.3 | 0.12em |

Labels are the only tracked text and are used sparingly, never as an eyebrow on every section.

## Shape

Radii: sheet 28, pill 22, control 18, tile 16, dock 30. Corners are continuous (iOS squircle). Strokes are hairlines; filled shapes carry hierarchy, not outlines.

## Spacing

4-point scale: xs 4, s 8, m 12, l 16, xl 20, xxl 24, xxxl 32. Screen gutter 16 on iPhone, 24 on Mac and iPad.

## Components

- **Status hero**: numeralHero battery or range on the ground, label beneath, no card.
- **Controls dock**: glass bar, radius 30, pill controls; accent fill while a command is in flight.
- **Tile**: glass, radius 16, title + numeralS; never nested.
- **Sheets**: glass, radius 28, drag handle, hairline header.
- **Map**: dark map tokens above; routes drawn in accent, optionally coloured by speed or power.
- **State chips**: charging / warning / danger colour plus a word, never colour alone.

## Motion

Ease-out quint, 180–260ms for state changes, 320ms for sheets. Live values tick without animation; a gauge fills once on appear and then only on change. Reduce Motion replaces every transition with a crossfade.

## Iconography

Lucide-style 1.5pt strokes at 20/24pt, ink or muted; accent only for the active state. The app icon is designed separately and must hold up in iOS tinted mode and at 16pt in the Mac Dock.
