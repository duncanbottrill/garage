# Mews app icon

Source of truth is `mews-icon.py` (`night()` builds the SVG for each appearance). The four SVGs here are its output:

| File | Used for |
|---|---|
| `ios-default.svg` | iOS Default, exported opaque 1024, no alpha (App Store rejects transparency) |
| `ios-dark.svg` | iOS Dark appearance, opaque 1024 |
| `ios-tinted.svg` | iOS Tinted appearance: greyscale glyph on transparent, iOS recolours it |
| `mac.svg` | macOS: artwork inset to the 824pt grid with the system shadow, transparent outside |

Regenerate the asset catalogue:

```bash
swiftc -O -o /tmp/svg2png svg2png.swift && swiftc -O -o /tmp/strip strip.swift
A=../../Garage/Assets.xcassets/AppIcon.appiconset
/tmp/svg2png ios-default.svg 1024 $A/AppIcon-1024.png && /tmp/strip $A/AppIcon-1024.png $A/AppIcon-1024.png
/tmp/svg2png ios-dark.svg 1024 $A/AppIcon-1024-dark.png && /tmp/strip $A/AppIcon-1024-dark.png $A/AppIcon-1024-dark.png
/tmp/svg2png ios-tinted.svg 1024 $A/AppIcon-1024-tinted.png
for s in 16 32 64 128 256 512 1024; do /tmp/svg2png mac.svg $s $A/mac-$s.png; done
```

Mark: a lowercase m drawn as two coach-house arches (a mews) with the bolt as its third leg, behind the arches. Field is the app's dark blue, accent #4FE3FF.
