# Alternate icons

Each `NAME.png` here becomes an app icon that Appearance > App icon offers. `scripts/pipeline.sh`
scales it for iPhone and iPad and adds it to Spotify's `Info.plist`.

- Square, 1024 × 1024, no transparency.
- `NAME` is letters, digits, `_` and `-`. An `_` shows as a space in the list.

`Glassify.png` (black, Spotify's green bars of glass) is also the home screen icon of `make release`. It and its
`_Green`, `_Aurora` and `_Daylight` variants are drawn by `source/glassify.html`; render one headless at 1024 × 1024:

    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars \
      --window-size=1024,1024 --virtual-time-budget=10000 --screenshot=icons/Glassify.png \
      "file://$PWD/icons/source/glassify.html?variant=midnight"

`source/reeded-light.html` is Vitrine's icon, kept as its source.
