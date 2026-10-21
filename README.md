# dusk

Dark mode and display brightness from the room's light, learned from you.

**Dusk.app** sits in the menu bar. Click it and it switches between light and
dark mode; right-click for what it sees and what it has learned. Every manual
switch that you do not undo within five minutes is a correction, and each one
retrains the model that decides when to switch on its own.

```
$ dusk status
ambient light
  sensor 20140000: 3.9 lx, 3207 K
  sensor 21140000: 2.1 lx, 5278 K
  sensor 22140000: 1.9 lx, 6066 K
  sensor 23140000: 2.5 lx, 5395 K
  median: 2.3 lx

sun and sky
  sun 4.2°, setting, counts as night; day today 07:43–17:01
  outdoors 35 W/m², 93% cloud

appearance: dark
  rules (either) say: dark; no model yet
…
running: Dusk.app
history: 2 samples, 0 confirmed correction(s) in ~/Library/Application Support/Dusk
```

## How it learns

Once a minute Dusk records a sample: each display sensor's lux and colour
temperature separately, the screens' brightness (the sensors see the screens'
own light), the sun's elevation and direction, minutes to sunset and since
sunrise, and outdoor irradiance and cloud cover from
[Open-Meteo](https://open-meteo.com), which is where the clouds come in: a
low summer sun and an overcast October afternoon at the same angle are very
different light.

When you switch by hand, Dusk keeps the room as it was at that moment, and
photographs it with each Studio Display camera. Switching back within five
minutes cancels both clicks; otherwise the correction is confirmed and the
model is retrained from:

- every confirmed correction, at full weight, and
- one moment per hour in which nobody touched the appearance, at low weight —
  the times it was already right.

The model is a small logistic regression over one feature or a pair, and
training is a search: every feature and every pair is cross-validated, a pair
has to beat the best single feature by a margin, and the winner is what the
menu shows ("dark when sun elevation < 6.9°", or a pair such as room light and
outdoor irradiance). Its probability has its own hysteresis (dark above 0.6,
light below 0.4, nothing in between) and the usual hold time. Until there is a
correction to learn from, the rules below decide.

Camera photos are features too (each camera's mean luma, and their median),
but only once they exist all the time: by default the camera runs only on
corrections, which is enough to keep the photos but not to predict from. Set
`cameraEveryMinutes` (say 10) and each capture's readings are carried into the
following samples until the next one, so the model can try them.
Photos stay on this Mac in `~/Library/Application Support/Dusk/photos`.

## Shortcuts

Dusk.app provides these actions:

| action | |
| --- | --- |
| Toggle Dark Mode | switches; *Teach Dusk* (on) makes it a correction |
| Set Appearance | light or dark; *Teach Dusk* is off, so automations do not train it |
| Get Appearance | light or dark |
| Get Room Light | median lux of the display sensors |
| Get Chance of Dark Mode | the model's probability now, 0…1 |
| Set Automatic Switching | pause or resume (recording and learning continue) |

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

**The cameras, as a second opinion.** On macOS `AVCaptureDevice` exposes
neither exposure time nor ISO (both are `API_UNAVAILABLE(macos)`), so a frame's
brightness is mostly what auto-exposure aimed for. Dusk records mean luma (and
EXIF brightness if a camera reports it) with every photo and lets the model
search decide whether it helps; the photos are mainly a record of what the room
looked like when you disagreed. The indicator light shows each capture.

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
  would fight, and restores it on `dusk uninstall`. Adjusting
  brightness by hand pauses dusk on that display for an hour.

Brightness and appearance go through DisplayServices and SkyLight, the private
frameworks behind the brightness keys and System Settings; there is no public
API for either. Symbols are resolved at runtime, so a macOS that drops one fails
with an error rather than at launch.

## Install

```sh
App/install.sh                             # builds Dusk.app into ~/Applications
swift build -c release && install -m 0755 .build/release/dusk ~/.local/bin/dusk
dusk config init --lat 52.39 --lon 13.12   # enables the sun and the weather
```

Building the app needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(App Intents metadata only comes out of an Xcode build); `project.yml` signs with
an Apple Development identity, so camera permission survives rebuilds. Dusk.app
registers itself to open at login, and retires the `dusk install` launch agent
if it finds one. Without the app, `dusk install` still runs the same engine as
a launch agent, learning from `dusk appearance dark --learn`.

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
| `eveningSunElevation` / `morningSunElevation` | – | separate thresholds for the setting and rising sun |
| `manageAppearance` | `true` | `false` for brightness only |
| `brightness.mode` | `curve` | `curve`, `fixed`, or `system` |
| `brightness.minLux` / `maxLux` | `1` / `20` | curve endpoints |
| `brightness.minimum` / `maximum` | `0.4` / `1.0` | curve range |
| `brightness.darkMaximum` | – | curve ceiling in dark mode |
| `brightness.light` / `dark` | `1.0` / `0.5` | `fixed` levels |
| `brightness.deadband` | `0.03` | ignore smaller changes |
| `intervalSeconds` | `15` | sensor poll interval |
| `smoothing` | `0.3` | weight of each new reading |
| `sampleSeconds` | `60` | how often a sample is stored |
| `useModel` | `true` | decide by the learned model once there is one |
| `modelDarkAbove` / `modelLightBelow` | `0.6` / `0.4` | the model's hysteresis |
| `cameraFilter` | `Studio Display Camera` | which cameras to use (substring) |
| `cameraOnCorrection` | `true` | photograph the room with each correction |
| `cameraEveryMinutes` | `0` | also on a schedule, so the camera can be a predictor |
| `photoRetentionDays` | `30` | delete scheduled photos after this; correction photos stay |

The defaults are a starting point: a desk lamp at night or a north-facing room
by day can put the two ends of the day closer together than you would think.
On the first day here, a cloudy midday read 13 lx — darker than the moment the
screens started to feel too bright at dusk — so lux alone could not tell the
two apart. What works is `"source": "either"` with `"eveningSunElevation": 7.5`:
the setting sun starts the evening, the room's light covers dark days, and the
morning still waits for sunrise.

The sensors also see the screens' own light: in dark mode, raising four
Studio Displays from 30% to 80% added about 1.7 lx, and a white light-mode
desktop adds more. That feedback makes the band self-reinforcing (bright
screens read brighter), which is why the evening is better left to the sun.
Run `dusk sense 60` for a while, or read the lux lines in the log, and set the
band between what you see at dusk and at midday.

## Commands

```
dusk status                  sensors, sun, displays, and what dusk would do
dusk sense [SECONDS]         print ambient light (repeat every SECONDS to calibrate)
dusk run                     decide once and apply, without the hold time
dusk watch                   keep deciding (what the launch agent runs)
dusk install | uninstall     manage the launch agent
dusk appearance light|dark [--learn]   set the appearance (and teach dusk)
dusk model [retrain]         the learned predictor
dusk corrections             every manual switch and what became of it
dusk brightness 0.8 | 80%    set every display's brightness by hand
dusk config [init --lat N --lon N]
```

## Test

```sh
swift test
```

The correction window, the model search (it must find a single separating
feature, and only pick a pair when neither feature works alone), examples,
features, policy, curve, smoothing, config, weather parsing and solar maths
are covered; sunrise and
sunset are checked against an independent implementation (USNO's *Almanac for
Computers* algorithm) to within three minutes.
