# dusk

Dark mode and display brightness from the room's light — a replacement for a
Shortcuts automation that asked the Weather app for sunrise and sunset every
five minutes.

```
$ dusk status
ambient light
  Studio Display @ 0x20140000: 26 lx, 4539 K
  Studio Display @ 0x21140000: 24 lx, 4713 K
  Studio Display @ 0x22140000: 30 lx, 4788 K
  Studio Display @ 0x23140000: 36 lx, 4629 K
  median: 28 lx

sun
  elevation 25.2°, up; today 07:43–18:00

appearance: light   verdict (ambient): light

displays (brightness mode: curve)
  Studio Display EC3A8BD7 (main): 100%, auto-brightness on
  …
```

## Why not the shortcut

`shortcuts run` from a launch agent every 300 s shows a Shortcuts Live
Activity each time, and rendering it costs `WidgetRenderer_Activities` about
two cores for half a minute — a visible stutter, twelve times an hour. dusk is
one small process that wakes every 15 s, reads the light sensors, and usually
does nothing.

## Where the light comes from

**The displays' own ambient light sensors.** A Studio Display has one (it drives
True Tone and auto-brightness), and presents it as a standard HID sensor-page
device: usage page `0x20`, usage `0x41`, illuminance in field `0x4D1`, colour
temperature in `0x4D2`. That is public IOKit, needs no entitlement and no
permission prompt, and works from a launch agent. With several displays, dusk
takes the median.

**The sun**, as a fallback when there is no sensor, or as a second opinion
(`"source": "either"`). Sunrise and sunset are computed locally from the NOAA
solar equations for the configured location — no network, no Weather app.

**Not the camera.** On macOS, `AVCaptureDevice` does not expose exposure time
or ISO (both are `API_UNAVAILABLE(macos)`), so a webcam frame's brightness is
mostly whatever its auto-exposure aimed for; it would also light the camera
indicator on every sample. The display sensors measure the same thing properly.

## What it does

- **Appearance.** Dark when the room stays below `darkBelowLux`, light when it
  stays above `lightAboveLux`; between the two nothing changes. A new verdict
  must hold for `holdSeconds` (3 min), so a passing cloud or someone leaning over
  the desk does not flip the theme. If you switch appearance by hand, dusk
  leaves it until its own verdict changes.
- **Brightness.** In `curve` mode, room lux maps onto brightness on a log scale
  (`minLux`→`minimum`, `maxLux`→`maximum`), smoothed, with a deadband, and faded
  rather than jumped. `fixed` reproduces the shortcut: one level for light mode,
  one for dark. `system` leaves brightness to macOS. While dusk drives
  brightness it turns macOS's own auto-brightness off, since two controllers
  would fight, and restores it when the agent stops or is uninstalled. Adjusting
  brightness by hand pauses dusk on that display for an hour.

Brightness and appearance go through DisplayServices and SkyLight, the private
frameworks behind the brightness keys and System Settings; there is no public
API for either. Symbols are resolved at runtime, so a macOS that drops one fails
with an error rather than at launch.

## Install

```sh
swift build -c release
install -m 0755 .build/release/dusk ~/.local/bin/dusk
dusk config init --lat 52.39 --lon 13.12   # optional: enables the sun fallback
dusk install                               # launch agent com.trieloff.dusk
```

Then retire the old automation:

```sh
launchctl bootout gui/$(id -u)/com.user.brightness
rm ~/Library/LaunchAgents/com.user.brightness.plist
```

`dusk uninstall` removes the agent and restores auto-brightness. The log is
`~/Library/Logs/dusk.log`; it records every change and the room's lux every ten
minutes, which is what you need to tune the thresholds.

## Configuration

`~/.config/dusk/config.json`; every key is optional.

| key | default | |
| --- | --- | --- |
| `source` | `ambient` | `ambient`, `sun`, or `either` |
| `darkBelowLux` / `lightAboveLux` | `8` / `15` | the hysteresis band |
| `holdSeconds` | `180` | how long a new verdict must hold |
| `latitude`, `longitude` | – | enables the sun |
| `sunElevation` | `-0.833` | "down" below this; `-6` waits for civil dusk |
| `manageAppearance` | `true` | `false` for brightness only |
| `brightness.mode` | `curve` | `curve`, `fixed`, or `system` |
| `brightness.minLux` / `maxLux` | `1` / `20` | curve endpoints |
| `brightness.minimum` / `maximum` | `0.4` / `1.0` | curve range |
| `brightness.light` / `dark` | `1.0` / `0.5` | `fixed` levels |
| `brightness.deadband` | `0.03` | ignore smaller changes |
| `intervalSeconds` | `15` | sensor poll interval |
| `smoothing` | `0.3` | weight of each new reading |

The defaults are a starting point: a desk lamp at night or a north-facing room
by day can put the two ends of the day closer together than you would think.
Run `dusk sense 60` for a while, or read the lux lines in the log, and set the
band between what you see at dusk and at midday.

## Commands

```
dusk status                  sensors, sun, displays, and what dusk would do
dusk sense [SECONDS]         print ambient light (repeat every SECONDS to calibrate)
dusk run                     decide once and apply, without the hold time
dusk watch                   keep deciding (what the launch agent runs)
dusk install | uninstall     manage the launch agent
dusk appearance light|dark   set the appearance by hand
dusk brightness 0.8 | 80%    set every display's brightness by hand
dusk config [init --lat N --lon N]
```

## Test

```sh
swift test
```

Policy, curve, smoothing, config and solar maths are covered; sunrise and
sunset are checked against an independent implementation (USNO's *Almanac for
Computers* algorithm) to within three minutes.
