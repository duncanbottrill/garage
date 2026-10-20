#!/usr/bin/env bash
# Downloads the two bundled typefaces (SIL OFL 1.1) and their licences into GarageKit's resources.
# Re-run to refresh; the files are committed, so builds never need the network.
set -euo pipefail
cd "$(dirname "$0")/.."
RES=GarageKit/Sources/GarageKit/Resources
FONTS="$RES/Fonts"
LICENSES="$RES/LICENSES"
# google/fonts commit pinned so a re-fetch reproduces the committed files; bump deliberately.
FONTS_SHA=47d54ca1ebb14fd864695f1d39dc734f39017c33
BASE=https://github.com/google/fonts/raw/$FONTS_SHA/ofl
mkdir -p "$FONTS" "$LICENSES"

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; echo "fetched $2"; }

fetch "$BASE/bigshouldersdisplay/BigShouldersDisplay%5Bwght%5D.ttf" "$FONTS/BigShouldersDisplay[wght].ttf"
fetch "$BASE/instrumentsans/InstrumentSans%5Bwdth%2Cwght%5D.ttf" "$FONTS/InstrumentSans[wdth,wght].ttf"
# Distinct names: the resources are processed (flattened) into one bundle, so two OFL.txt files would collide.
fetch "$BASE/bigshouldersdisplay/OFL.txt" "$LICENSES/BigShouldersDisplay-OFL.txt"
fetch "$BASE/instrumentsans/OFL.txt" "$LICENSES/InstrumentSans-OFL.txt"

# Sanity check: both files must be TrueType (0x00010000 header), not an HTML error page.
for f in "$FONTS"/*.ttf; do
  [ "$(head -c 4 "$f" | xxd -p)" = "00010000" ] || { echo "not a TrueType font: $f" >&2; exit 1; }
done
