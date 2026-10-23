# Product

## Register

product

## Users

One Tesla owner (the author) first, on iPhone and Mac, with the app built so a public release is a change of hosting and accounts rather than a rewrite. They open it dozens of times a day for a glance: is the car locked, how much charge, is it warming up, when does the next charge finish. Longer sessions are review sessions: scrolling drives and charges, checking cost per mile, looking at battery health. Context is a pocket glance on the pavement, a desk window on the Mac, and later a wall iPad in the hallway that is read, not touched.

## Product Purpose

Mews is a Tessie-class companion for a Tesla, built directly on Tesla's Fleet API and a home-run bridge. It shows live state within seconds, lets the owner lock, heat, charge and open the frunk from anywhere, and logs every drive and charge from day one so later slices (drives, charges, places, insights, battery) have real data. Success is the owner deleting Tessie, the Tesla API bill staying inside the free credit, and the app feeling calmer and sharper than the official one.

"Mews" is the row of converted coach houses behind a London terrace: the quiet home your car comes back to.

## Brand Personality

Composed, precise, quietly technical. The voice is a trusted mechanic who happens to be a good designer: short sentences, numbers you can trust, no cheerleading. Three words: calm, exact, nocturnal. Emotional goal: the reassurance of a dashboard at night. Everything important is lit, nothing shouts.

## Anti-references

- The official Tesla app's flat white sheets and generic SF-symbol controls. Mews should never be mistaken for it.
- Tessie's own look: dense list rows, default system blue, stock iOS chrome. We respect the feature set, not the skin.
- EV cliches: lime-green leaves, lightning bolts in gradient circles, "eco" iconography, Tesla's T logo or anything close to it.
- SaaS dashboard tropes: hero-metric tiles with gradient accents, identical stat cards, tiny uppercase eyebrows on every section.
- Gamer dark mode: neon on black, glow on everything, RGB gradients.

## Design Principles

1. **Glance first, depth second.** The important number is readable from arm's length; detail is one tap away and never competes with it.
2. **Numbers are the typography.** Big Shoulders numerals carry the hierarchy. Chrome, cards and icons stay quiet so the data reads.
3. **Light only what matters.** One accent, used for state and action. Status colours (charging, warning, danger) appear only when that state is true.
4. **Honest about the car.** Show when data is stale, when the car is asleep, when a command is still in flight. Never fake freshness.
5. **Nothing wakes the car.** Every design choice respects the API budget: no refresh-on-pull theatre, no polling for a prettier chart.

## Accessibility & Inclusion

- Target WCAG 2.1 AA for text contrast on the dark palette; ink on background is well above, muted text is checked per use.
- Status is never colour alone: charging, warning and danger states carry a label or glyph as well.
- Respect Reduce Motion (no animated gauges or map sweeps) and Dynamic Type for body and labels; display numerals scale within a bounded range.
- Controls meet 44pt targets on iPhone; Mac keeps keyboard focus and full-keyboard access for every command.
- Icon and glyph work must survive monochrome (tinted iOS icons, Mac Dock at 16px) and colour-vision deficiency: cyan accent against a near-black ground, never red/green distinctions.
