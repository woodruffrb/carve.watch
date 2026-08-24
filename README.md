# carve

**Wrist telemetry for self-balancing single-wheel boards.**

A free, open source Garmin Connect IQ watch app. Speed, state of charge and
trip distance on your wrist, with alerts for faults and for the conditions that
precede them — so you find out the board is running out of margin before the
board tells you by pitching you off it.

Made by [Derivative.Engineering](https://derivative.engineering).
MIT licensed. No accounts, no telemetry, no ads, no paid tier.

---

## What it does

- **Speed, board battery, trip distance** at a glance, in a layout built for
  reading at speed rather than for looking good in a screenshot.
- **Every slot is configurable.** Four slots, fourteen metrics, set from Garmin
  Connect. Speed, board battery, trip, motor temperature, pack voltage, safety
  headroom, ride time, max/average speed, watch battery, clock, heart rate,
  wheel RPM.
- **Alerts that mean something.** Safety headroom, motor temperature, board
  battery and fault flags, each with its own thresholds, each edge-triggered so
  you get told once rather than buzzed continuously.
- **Rides record to FIT.** Board battery, motor temperature, headroom and pack
  voltage ride along as developer fields, so a finished ride opens in Garmin
  Connect with the board's own numbers graphed against your GPS track.
- **Works on MIP and AMOLED.** High-contrast palette on transflective displays,
  burn-in-safe layout and a dim always-on state on OLED.

## Supported watches

Requires Connect IQ **3.1.0** or later, `BluetoothLowEnergy` support, and
enough watch-app memory for the BLE stack alongside a UI.

Reference device is the **fēnix 6 Sapphire** (`fenix6pro`). Also built for
fēnix 6 / 6S Pro, fēnix 7 / 7S / 7X, epix (Gen 2), Forerunner 945 / 955 / 965,
Venu 2 / 2S, and vívoactive 4 / 4S.

Adding a device is one line in `manifest.xml`, but check the Connect IQ Device
Reference for `BluetoothLowEnergy` support first — a device without it will
build cleanly and then do nothing at all.

## Supported boards

Built and tested against the **XR** protocol. Boards using the same GATT service
should work; the tire circumference setting is what adapts speed to a different
wheel.

Later-generation boards use a different, less-documented handshake and are **not
supported yet**. See [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

## Install

Not yet on the Connect IQ Store. To side-load:

1. Install the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/)
   and download your device in the SDK Manager.
2. Build for your watch (see [Building](#building) for the toolchain setup).
3. Copy the `.prg` built for **your exact device** to `GARMIN/Apps/` over USB
   (check `GarminDevice.xml` on the watch - a wrong-target build installs and
   runs but its BLE silently does nothing),
   and eject.

Settings live in Garmin Connect → your device → Connect IQ Apps → carve, or in
Garmin Express.

## First run

The app scans on launch and connects to the first board advertising the
expected service. The status line reads `SEARCHING` → `CONNECTING` →
`HANDSHAKE`, then disappears once telemetry is flowing — a healthy link says
nothing, because a permanent "connected" badge is noise you learn to ignore.

**If it sticks on `HANDSHAKE`** and then shows `UNLOCK FAILED`, the
challenge-response is being rejected. There is one genuinely ambiguous detail in
the published protocol and it is isolated to a single constant — see
[`docs/PROTOCOL.md`](docs/PROTOCOL.md#the-one-genuinely-uncertain-detail).

**Calibrate speed before trusting it.** Speed is derived from wheel RPM and tire
circumference, not GPS. Ride a steady speed on the flat, compare against the
watch's own GPS speed, and adjust *Tire circumference* until they agree. The
default is the XR rollout.

**Diagnostics** (MENU → Diagnostics) shows raw decoded values next to the link
state. That is the screen to use when verifying the characteristic map against
your own board.

## Building

The Connect IQ SDK is a Java toolchain and ships no runtime of its own, so a
**JDK 17 or newer** must be on `PATH`. Built and verified against SDK **9.2.0**
with Microsoft OpenJDK 21.

A one-off developer key is needed to sign builds. It is gitignored — generate
your own:

```bash
openssl genrsa -out developer_key.pem 4096 && openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt
```

Build for a single device:

```bash
monkeyc -f monkey.jungle -d fenix6pro -o bin/carve-fenix6pro.prg -y developer_key.der -w
```

Build the store package for every device in the manifest:

```bash
monkeyc -f monkey.jungle -o bin/carve.iq -y developer_key.der -e -w
```

Both are expected to produce **zero errors and zero warnings**. Warnings are
worth keeping at zero here — the type checker is what catches the container
and nullability mistakes that Monkey C otherwise defers to a crash on-wrist.

To run in the simulator:

```bash
connectiq && monkeydo bin/carve-fenix6pro.prg fenix6pro
```

`monkeydo` stays attached while the app runs; that is normal, not a hang.

The app uses about **32 KB** of the 1275 KB available to a watch app on a
fēnix 6X, so there is ample headroom for more fields.

Note that the simulator has no BLE without a supported USB dongle, so the app
sits at `OFFLINE` there — profile registration never calls back. That is
expected, and the only way to exercise the handshake off-board is with a
dongle driving a real peripheral.

## Design notes

Three constraints shaped the architecture, and they are worth knowing before
changing anything:

**The keepalive owns the app.** The board stops refreshing telemetry unless it
is re-challenged within 24 seconds. The timer therefore lives in `CarveApp`, not
in any `View` — a view is destroyed when you open the menu, and a keepalive that
died with it would freeze the display 24 seconds into a menu dive.

**One GATT operation at a time.** Connect IQ silently drops a second read issued
before the first completes. Every operation goes through the queue in
`BoardLink`, dispatched singly and advanced by completion callbacks. Adding a
direct `requestRead()` anywhere else will appear to work and then intermittently
lose data.

**Registration budget is finite.** Connect IQ caps registered profiles at three,
and every characteristic and descriptor costs memory whether subscribed or not.
`BoardUuids.registeredCharacteristics()` is the deliberate minimum. Adding a
field means adding its characteristic there too, then re-testing on hardware.

## Read-only, on purpose

carve **reads** telemetry. It writes exactly two characteristics, both required
by the handshake, and nothing else. It does not change ride modes, does not
touch lights, does not modify firmware, and will not gain those features.

Reading data a device already broadcasts to any paired client, for
interoperability, is a different posture from modifying how that device behaves.
Please keep pull requests on the reading side of that line.

## Safety

This is a **secondary display for information the board already provides**. It
is not a safety system.

- Alerts can be late, wrong, or absent — BLE drops, values go stale, and the
  app shows `--` rather than guessing.
- Derived speed is only as accurate as your circumference setting.
- Nothing here changes how the board rides, and no reading from it means the
  board is safe to ride.

Wear a helmet. Riding these boards carries a real risk of serious injury.

## Contributing

Issues and pull requests welcome. Most valuable right now:

- **Protocol verification.** Most of the characteristic map is
  community-reported rather than confirmed. Dumps from real hardware, especially
  non-XR boards, are the single most useful contribution.
- **Device coverage.** Build for your watch and report what breaks.
- **Layout on small round displays.** 218 px devices are tight.

## Trademarks

carve is an independent project. It is not affiliated with, endorsed by, or
sponsored by Garmin Ltd. or by any board manufacturer. All product names,
trademarks and registered trademarks are the property of their respective
owners, and are used here only to describe compatibility.
