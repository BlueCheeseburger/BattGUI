# BattGUI

A native macOS app for [batt](https://github.com/charlie0129/batt), the battery charging tool for Apple Silicon MacBooks.

## What you can do

- **Battery:** see charge level, charging state, voltage and charge rate at a glance.
- **Power adapter:** cut or restore wall power without unplugging, so the battery can drain while the charger stays connected.
- **Charge limit:** set an upper limit (10–100%), charge to 100% now or for a set time, and choose how far below the limit charging resumes.
- **Sleep:** stop charging before sleep, stay awake while charging, or block all sleep until the limit is reached.
- **MagSafe LED:** show charging status on the LED, leave it to macOS, or keep it off.
- **Calibration:** start, pause, resume or cancel a calibration cycle, tune its settings, and schedule it with cron.
- **Activity log:** see the output of every command BattGUI runs.

Features your Mac doesn't support are greyed out automatically, based on what batt detects on your hardware. For example, macOS 27 firmware blocks third-party charge control, so on those Macs BattGUI points you to the built-in Charge Limit in System Settings instead.

The app icon switches to a dark version when your icon style is set to dark.

## Requirements

- A MacBook with Apple Silicon, running macOS 14 or later
- [Homebrew](https://brew.sh) and batt, with its daemon running:

  ```bash
  brew install batt
  sudo brew services start batt
  ```

- Xcode Command Line Tools (for `swiftc`)

## Build

```bash
./build.sh
```

This compiles the app, generates the light and dark icons, signs the bundle ad hoc and installs it to `/Applications/BattGUI.app`.

Settings that change battery behavior ask for your administrator password, since batt needs root to apply them.
