# Mews — Slices 2 and 3 design baseline (Figma pass)

**Status:** decisions agreed with Duncan 2026-10-22, feature by feature. Ready for the Figma pass in the order below.
**Purpose:** the brief for the Figma design of slice 2 (Logging) and slice 3 (Battery and insight), to be reviewed page by page.
**Design direction:** "04 Hybrid" (dark, Big Shoulders Display numerals, Instrument Sans text, accent `#4FE3FF`, glass cards, hairlines), as built in slice 1.
**Platforms:** iPhone first, Mac as the wide layout of the same screens. The wall dashboard is a web page.

How to read each feature: **Tessie does** is what Tessie ships (help-centre facts marked ✓, my working knowledge of the app marked ~). **Mews baseline** is what I propose we design unless you say otherwise. **Questions** are the ones that change what gets drawn.

---

## 0. Navigation and the shape of the app

**Tessie does** ~ A home screen of tiles (Drives, Battery, Charges, Idles, Alerts, Automation, Sentry, Locations, Statistics, Settings), each opening a section with its own list, detail and Analytics tab. A date-range picker (day, week, month, year, custom, since last charge) sits on every list and analytics view.

**Decided 2026-10-22** Tabs: **Status · Drives · Charges · Insights · More**. Battery health is the hero section at the top of Insights (people check it on its own, but it is an insight), followed by period summaries, patterns and the year view. Places, Costs and exports live under More. Every list has the same period picker (week by default, then month, year, custom, since last charge). On Mac the tabs become the sidebar, with Battery allowed its own sidebar entry, and list + detail sit side by side.

Idles have no list. Parked time is a quiet row between drives ("Parked at home · 14 h · −2%"), tappable for a small detail, and overnight loss is a chart in Insights.

---

## 1. Drives

**Tessie does** ✓ Records every drive automatically; Drives page = history with maps and analytics; CSV export and import; range efficiency = range used ÷ real-world miles; energy from state of charge; Wh/mi. ~ List rows: start → end place, time, distance, duration, efficiency. Detail: route on map, start/end battery %, energy used, Wh/mi, range efficiency %, average and top speed, outside temperature, cost (period-average £/kWh), fuel savings vs a petrol car, tags, notes. Analytics: energy, efficiency, speed, cost, distance over the period, efficiency vs temperature.

**Decided 2026-10-22**
- *List*: grouped by day; row = place to place, time, distance, duration. Nothing else competes for the eye.
- *Detail*: route map on top with the polyline **coloured per segment by speed or by power** (Speed / Power toggle above the map; regen its own colour on Power; scrub along the route shows the value and time). No separate trace chart. Then the numbers band (distance, duration, Wh/mi, battery used, cost, fuel saving vs petrol), then a **Conditions** strip, then tags and a note.
- *Conditions*: outside temperature (car); rain, wind speed and direction with the headwind component against the route heading (Open-Meteo archive, one lookup per drive); elevation gain and loss (route); climate energy share and regen share (car).
- *Recurring routes*: the same start and end places more than three times make a route; the detail then says "Commute · 9% better than your average", and routes are a filter in analytics.
- *Merging*: a stop under 5 minutes with no door open is one drive; otherwise two.
- *Cost*: energy used × the blended £/kWh of the charges that fed it.
- *Tags and notes*: kept; tags filter the list and the analytics.
- *Analytics*: period totals (distance, energy, cost, fuel saving), efficiency trend, efficiency vs temperature, vs headwind and vs elevation, longest and most efficient drives, by tag and by route.
- *Export*: CSV of the selected period.

---

## 2. Charges

**Tessie does** ✓ Charges page = history with maps and analytics; energy added (from the car) vs energy used (from charger volts × amps), efficiency = added ÷ used (≈90% AC, ≈100% DC); costs per saved location with Update Charging History to backfill; default £/kWh fallback; Supercharger costs synced from the Tesla account; foreign currency converted. ~ Detail: location, start/end %, kWh added, kWh used, cost, duration, charger type (AC/DC) and peak kW, range added, a power-over-time chart, charge limit. Analytics: kWh and cost per period, home vs away split, average cost per kWh.

**Decided 2026-10-22**
- *Live card*: while charging, a card at the top of Charges shows power now, kWh so far, cost so far and time to limit; tapping it opens the same detail layout, live.
- *List*: grouped by day; row = place, time window, +kWh, start→end %, cost, AC/DC glyph.
- *Detail, adaptive hero*: **DC sessions lead with the charge curve** (kW against % and against time, limit marked, full width) with the numbers band under it; **AC sessions lead with the numbers band** (kWh added, kWh used, efficiency, cost, duration, peak kW) with the curve as a small card lower down. Same parts, two orderings, chosen by charger type. Then the tariff breakdown when the session crossed rate periods, and a note.
- *Cost*: per-place tariff, £/kWh only (no per-session or per-minute pricing needed); flat rate in slice 2, Octopus half-hourly in slice 3; Supercharger sessions from Tesla invoices when available, else a manual entry.
- *Analytics*: kWh and £ per period, **split per place** (home, work, Supercharger, others), £/kWh trend, kWh per month bars.
- *Alerts belong to slice 1's notification follow-up, not here.*

---

## 3. Places (saved locations)

**Tessie does** ✓ Save a location from any drive, charge or idle; circle boundary with radius slider; label; unlocks cost tracking, filtering, exports, arrive/leave alerts, unplugged alerts, automations. ~ A Locations page listing them with visit counts.

**Decided 2026-10-22**
- Two fixed places, **Home** and **Work**, pinned at the top with their own icons; everything else is an occasional place (holiday lets, family, a Supercharger) added from a drive or charge detail with one tap. The list stays short, so no search; a "last visited" sort keeps the current trip's places on top.
- Place sheet: name, icon, radius on a small map, tariff (optional), and a **Preferences** group shown disabled for now: default charge limit, precondition on arrival. The layout is ready for automations later.
- Drives and charges show the place name wherever an address would appear.
- Alerts are out of scope for the Figma pass.

---

## 4. Idles (parked time) and sleep

**Tessie does** ✓ Idle = any time not driving or charging; Idles page with maps and analytics; phantom drain shown; sleep score added in 15.7 with sleep/offline shading on graphs. ~ Each idle: place, duration, % and kWh lost, whether Sentry or climate was on, time asleep vs awake.

**Decided 2026-10-22**
- No Idles tab. Each idle is a quiet row between drives ("Parked at home · 14 h · −2%"), tappable for a small detail (energy lost, asleep share, Sentry on, climate on).
- Insights shows overnight loss per night with asleep share.
- **Sleep shading** on time charts (battery level, overnight loss): asleep, awake and offline stretches read as three distinct bands behind the line. Drawn in the Figma pass to judge; dropped if it clutters.

---

## 5. Battery (slice 3)

**Tessie does** ✓ Range health = current range at 100% ÷ original range; capacity and range recorded after each charge > 5 kWh from the BMS estimates; cycles counted as full-charge equivalents, pre-activation cycles estimated; original capacity from the average for the model, user-overridable; battery-replacement date; warns that firmware changes move the numbers. ~ Screen: health % hero, capacity kWh and range at 100 %, degradation chart over time with the fleet band, cycles, a "likely BMS drift, recalibrate" note.

**Decided 2026-10-22**
- *Hero*: a **gauge infographic** that carries both figures: the arc is usable capacity in kWh against the original (the honest number), the big numeral is health %, and the confidence band is a soft wedge on the arc from the spread of our own readings (one car, so no fleet band). Cycles and range at 100 % sit as small figures beside it.
- *Projection*: shown under the gauge ("At this rate, 90 % at about 60k miles"), fitted to the median readings, with the caveat that software updates move the BMS numbers; it recomputes after each reading.
- *Charts*: capacity over time (readings after every charge > 5 kWh, median line, raw points faint), DC charge-curve overlays (kW vs %, sessions coloured by age), efficiency vs outside temperature (scatter with fitted curve), overnight loss per night with sleep shading. **Equal-weight cards in a stack, capacity first** because it backs the gauge; which one earns the top slot is decided after seeing them drawn.
- Octopus half-hourly tariff lives in Charges, not here.

---

## 6. Costs and tariffs

**Tessie does** ✓ Default £/kWh; per-location rate; Supercharger invoices synced; currency conversion; drives and idles costed at the period-average £/kWh. ~ Time-of-use periods per location (users mention 30-minute granularity); Fuel Costs page comparing with a petrol car.

**Decided 2026-10-22**
- Slice 2: a flat £/kWh per place plus one default; Supercharger cost from the Tesla invoice when available, else entered by hand.
- Slice 3: **Intelligent Octopus Go** for the home place. Two rates (off-peak 23:30–05:30 and peak) plus the **extra smart slots** Octopus schedules when the car is plugged in, read from the Octopus API dispatches. The charge detail shows the night as a timeline: the fixed window, the bonus slots, and the session's kWh laid over them, with the cost split into off-peak and peak kWh. No price graph is needed (that is Agile).
- Status and the Charges live card show "cheap rate now" / "next cheap slot at 23:30" when the car is plugged in at home.
- Costs page under More: this month's £ by place, off-peak share, £/kWh trend, **£ per mile**. No petrol comparison here; the drive detail keeps its fuel-saving figure.

---

## 7. Wall dashboard (web)

**Tessie does** ~ A web dashboard (dash.tessie.com) mirroring the app: map, live state, lists; owners find it sparse.

**Decided 2026-10-22** An **iPad in the kitchen**, always on, **read-only**: controls stay on the phone, so nothing on the wall can move or open the car. The wall is a web page (or the iPad app in a Wall layout; the drawing is the same and the choice is made at build time). Landscape iPad frame, readable from across a room: battery and range large, plugged-in and charging state with "cheap rate now / next cheap slot", last drive, today's energy and £, inside and outside temperature, a small map. Dark, 04 Hybrid, no chrome.

---

## 8. Statistics and exports

**Tessie does** ~ Statistics page with lifetime and per-period totals; CSV export per section; calendar heat map of drives.

**Decided 2026-10-22** No statistics in the lists at all: Drives and Charges stay quiet, lists only. **Insights is the statistics page**: period summaries with last-period comparison, patterns, the year heat map, and Battery at the top. CSV exports for drives and charges live under More.

---

## 9. Insights (new tab)

**Decided 2026-10-22** The fourth tab, and the home of everything cross-cutting:
1. **Battery** hero (section 5): gauge, projection, charts.
2. **This period** against the last: distance, kWh, £, £ per mile, Wh/mi, off-peak share; period picker shared with the lists.
3. **Patterns**: efficiency vs temperature, vs headwind, vs elevation; home vs public share; charging hours against the cheap window; by tag and by route.
4. **Verdicts**: short generated lines with the number behind them ("Winter cost 22% more per mile", "Overnight loss up since the last update").
5. **Year**: calendar heat map of drives and charges; a yearly review page later.

---

## Order of work in Figma

1. Navigation frame and shared parts: period picker, list row, numbers band, chart card, place chip, coloured route. Components only with Duncan's go-ahead, as variants of one set each.
2. Drives: list (with parked rows), detail with the coloured route and Conditions strip, analytics.
3. Charges: live card, list, the two detail orderings (DC curve-first, AC numbers-first), Octopus night timeline, analytics.
4. Places: list with Home and Work pinned, the place sheet with disabled Preferences.
5. Insights: Battery gauge and charts with sleep shading, period summary, patterns, verdicts, year view.
6. More additions: Costs page, exports.
7. Wall iPad, landscape, read-only.
8. Mac layouts of 2 to 5.

Each step is reviewed before the next starts.

---

## Sources

Tessie help centre: drive tracking (article 43), charge tracking (143), battery health (39), saved locations (52), idle tracking (144), charging efficiency (49), automatic charging costs (54), understanding costs (69), driving efficiency (59); Tessie announcements "What's new in 15.7" and "16.1"; owner reviews on Drive.com.au, lesterchan.net and Tesla Motors Club threads. Items marked ~ are from using the app, not from a document.
