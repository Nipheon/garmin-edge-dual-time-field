# Smart Time and ETA Field

Available in the Connect IQ store: [Time/ETA Field (Smart)](https://apps.garmin.com/apps/f1ad368b-6143-4482-8476-1f820ab3ecbe)

A Connect IQ data field for Garmin Edge cycling computers that shows the time of
day and, when a course is loaded, when you will arrive.

- **No course:** one big value, the current time (12 or 24 hour, following the
  device setting).
- **Course loaded:** two values, the current time and either the arrival time
  (ETA) or the remaining duration. Choose in the field's settings
  (**Route Mode Display**); the default is arrival time.
- **ETA:** distance to the destination divided by a smoothed recent speed, so it
  does not jump at every red light. Stops are ignored and the estimate catches
  up quickly after you set off again. Before there is enough riding data it
  falls back to the ride's average speed.

The layout copies how Garmin's own data fields look: the same slot sizes,
header fonts and value sizes per device. Value fonts are bundled number fonts
generated from Garmin's Roboto Bold, because Connect IQ cannot scale fonts the
way the built-in fields do.

## Supported devices

Edge 520 Plus, 530, 540, 550, 820, 830, 840, 850, 1030, 1030 Plus,
1030 Bontrager, 1040, 1050, Explore, Explore 2 and MTB. Minimum API level is
2.4.0, so the Edge 820/Explore units on the older 2.4 firmware are included.

Languages: English, German, French, Spanish, Italian, Portuguese, Dutch.

## Status

Version 1.5.0. Tested on an Edge 1040.

## Build

```sh
SDK="$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/<current-sdk>"

# One device, then run in the simulator
"$SDK/bin/monkeyc" -o bin/edge1040.prg -f monkey.jungle -y ../developer_key -d edge1040 -w
"$SDK/bin/connectiq" &
"$SDK/bin/monkeydo" bin/edge1040.prg edge1040

# Store package for every supported device (dist/ is gitignored)
mkdir -p dist
"$SDK/bin/monkeyc" -e -r -o dist/DualTimeField-<version>.iq -f monkey.jungle -y ../developer_key -w
```

`../developer_key` is your own Connect IQ developer key, kept outside the repo.
A `.prg` installs only on the device it was built for: copy it to
`/Garmin/Apps/` on the Edge. The `.iq` store package cannot be sideloaded.

## Tools

- `tools/gen_number_fonts.py` regenerates the bundled number fonts (needs
  Pillow and Garmin's `Garmin_Roboto_Bold.ttf` from the SDK).
- `tools/layout_verify.py` checks the layout math for every slot size and
  device from per-device font metrics dumped from the simulator
  (`METRICS_DIR`).

## Licenses

The bundled number fonts are bitmaps derived from Roboto Bold (Copyright 2011
Google Inc., Apache License 2.0). See `NOTICE` and `licenses/Apache-2.0.txt`.
The font file itself is not included.

## AI disclosure

This app was built with the help of AI: Claude (Anthropic). The author reviews
the results and directs the project.
