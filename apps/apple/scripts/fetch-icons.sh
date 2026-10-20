#!/usr/bin/env bash
# Downloads the Lucide icons (ISC licence) the app uses into GarageKit's asset catalog as template,
# single-scale vector image sets. Re-run to refresh; the assets are committed.
set -euo pipefail
cd "$(dirname "$0")/.."
RES=GarageKit/Sources/GarageKit/Resources
CATALOG="$RES/Icons.xcassets"
LICENSES="$RES/LICENSES"
BASE=https://unpkg.com/lucide-static@latest
ICONS=(lock lock-open thermometer snowflake flame battery-charging plug plug-zap car-front navigation map-pin fan wind
       zap clock refresh-cw settings chevron-right circle-alert wifi-off check x sun moon gauge route)
mkdir -p "$CATALOG" "$LICENSES"

VERSION=$(curl -fsSL --retry 3 "$BASE/package.json" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1)
echo "lucide-static $VERSION"

cat > "$CATALOG/Contents.json" <<JSON
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

for name in "${ICONS[@]}"; do
  set_dir="$CATALOG/$name.imageset"
  rm -rf "$set_dir"; mkdir -p "$set_dir"
  # Lucide strokes with currentColor; the asset catalog's SVG renderer wants a concrete colour. The sets are
  # templates, so only the alpha matters and SwiftUI tints them with foregroundStyle.
  curl -fsSL --retry 3 "$BASE/icons/$name.svg" | sed 's/currentColor/#000000/g' > "$set_dir/$name.svg"
  grep -q "<svg" "$set_dir/$name.svg" || { echo "not an SVG: $name" >&2; exit 1; }
  cat > "$set_dir/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "$name.svg", "idiom" : "universal" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }
}
JSON
  echo "icon $name"
done

curl -fsSL --retry 3 -o "$LICENSES/Lucide-LICENSE.txt" "$BASE/LICENSE"
printf 'lucide-static %s\n' "$VERSION" > "$LICENSES/Lucide-VERSION.txt"
