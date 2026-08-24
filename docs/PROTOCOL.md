# Board BLE protocol notes

Everything here is community-reverse-engineered for **interoperability**:
reading telemetry the board already broadcasts to any paired client.
carve.watch is deliberately **read-only** — see [Read-only rule](#read-only-rule).

## Confidence levels

Each value below is tagged:

- **[V]** verified against published documentation during design
- **[C]** community-reported, consistent across multiple projects, **not yet
  confirmed on hardware**

Anything marked **[C]** should be confirmed with the on-device dump mode
(hold MENU on the ride screen → *Diagnostics* → *Dump characteristics*)
before being trusted. `chrome://bluetooth-internals` on a desktop is the
faster way to do the same job.

## Service

| UUID | Meaning | Conf |
|---|---|---|
| `e659f300-ea98-11e3-ac10-0800200c9a66` | Primary board service | **[V]** |

Confirmed as a PRIMARY SERVICE by GATT dump of an XR (`OW111222`) on
2026-08-23. The board exposes a contiguous characteristic range `e659f301`
through at least `e659f320`, plus the two UART characteristics.

All characteristics share the `e659fXXX-ea98-11e3-ac10-0800200c9a66` pattern;
only the third group varies, so the code stores the 16-bit short form and
expands it.

## Advertising

Verified from a scanner capture of an XR, 2026-08-23:

```
Complete Local Name:   ow111222          (lowercase on the wire)
128-bit Service UUIDs: e659f300-ea98-11e3-ac10-0800200c9a66
Device type:           LE only
Advertising type:      Legacy
Flags:                 LE General Discoverable, BR/EDR Not Supported
Manufacturer data:     Company 0x0301 (Giatec Scientific Inc.)
Advertising interval:  ~106 ms
```

Two things follow.

**The service UUID is in the advertisement**, not merely in the GATT table, so
matching on `ScanResult.getServiceUuids()` works. That is the primary match.

**The advertised name is lowercase.** The name appears capitalised in some
UIs, so any name-based matching must be case-insensitive. `BoardLink` matches
the first two characters lowercased, and falls back to this only when the
service UUID is absent from the advert.

The manufacturer company ID belongs to an unrelated instrumentation vendor and
is almost certainly an unmodified default from an off-the-shelf BLE module.
Do not filter on it - it is exactly the sort of value that changes silently
with a hardware revision.

## Characteristics

| Short | Name | Type | Conf |
|---|---|---|---|
| `f301` | Serial number | uint16 | **[C]** |
| `f302` | Ride mode | uint8 | **[C]** |
| `f303` | Battery remaining | uint8 (%) | **[C]** |
| `f304` | Battery low 5% flag | uint8 | **[C]** |
| `f305` | Battery low 20% flag | uint8 | **[C]** |
| `f307` | Pitch | uint16 | **[C]** |
| `f308` | Roll | uint16 | **[C]** |
| `f309` | Yaw | uint16 | **[C]** |
| `f30a` | Trip odometer | uint16 | **[C]** |
| `f30b` | RPM | uint16 | **[C]** |
| `f30f` | Status / error flags | uint16 | **[C]** |
| `f310` | Temperature | uint16 | **[C]** |
| `f311` | Firmware revision | uint16 | **[V]** |
| `f312` | Current amperage | int16 | **[C]** |
| `f313` | Battery voltage | uint16 | **[C]** |
| `f317` | Safety headroom | uint8 | **[C]** |
| `f319` | Lifetime odometer | uint16 | **[C]** |
| `f31c` | Last error code | uint16 | **[C]** |
| `f3fe` | UART serial **read** | notify only | **[V]** |
| `f3ff` | UART serial **write** | write only | **[V]** |

Multi-byte values are **big-endian**.

### Properties (verified)

The GATT dump settles what these characteristics can do, which is separate
from what they *mean*:

- **`f301`–`f320`**: every one is `NOTIFY, READ, WRITE`, each carrying both a
  CCCD (`0x2902`) and a Characteristic User Description (`0x2901`). So any
  telemetry value can be either subscribed or polled - the choice in
  `BoardUuids.notifyCharacteristics()` is about resource use, not capability.
- **`f3fe`**: `NOTIFY` only, with a CCCD. The read side of the UART pair.
- **`f3ff`**: `WRITE` only, no CCCD. The write side.

The UART pair is now verified, which removes the largest single risk in the
handshake: the response is being written to the right characteristic.

### The 0x2901 descriptors are a dead end - do not retry this

Every characteristic carries a Characteristic User Description (`0x2901`),
which looks like it should name each value. It does not. Read back on an XR
they return `Data#N`, where N is simply the low byte of the UUID in decimal:

| Characteristic | 0x2901 value |
|---|---|
| `e659f31e` | `Data#30` |
| `e659f31f` | `Data#31` |
| `e659f320` | `Data#32` |

`0x1e` = 30, `0x1f` = 31, `0x20` = 32. They are auto-generated indices with no
semantic content - the firmware never populated real names. Checked
2026-08-23; do not spend time here again unless a much later firmware is
known to have filled them in.

**Identification is therefore empirical.** Read a characteristic's value while
the board is in a state you can verify independently, and match. The
discriminating moves:

- **Battery**: compare against the percentage the stock app reports.
- **RPM**: zero at rest, non-zero while the wheel is spun by hand. This is the
  cleanest single test, because spinning the wheel changes almost nothing
  else.
- **Trip odometer**: compare against the stock app, and check it increments
  over a short push.
- **Temperature**: near ambient on a cold board, climbing after a ride.

Values render as big-endian byte pairs - `(0x) 00-01` is 1 - which is
consistent with the uint16 decoding in `BoardLink.decode()`.

## The unlock handshake

Newer firmware stops refreshing the telemetry characteristics unless the
client re-authenticates. **The window is 24 seconds** — carve.watch re-arms at
15 s for margin.

Sequence (**[V]** — from the documented 13-step procedure):

1. Read the firmware revision characteristic (`f311`).
2. Subscribe to the UART read characteristic (`f3fe`) by writing `01 00` to
   its CCCD (`00002902-...`).
3. Write the firmware revision value **back** to `f311`. This is what asks the
   board for a challenge.
4. Accumulate notification bytes from `f3fe` until 20 have arrived.
5. Verify the first three bytes are `43 52 58` (`"CRX"`).
6. `MD5(challenge_payload || STATIC_KEY)`.
7. Response = `43 52 58` ++ `md5_digest` ++ `xor_checksum`.
8. Write the response to `f3ff`.

Static key (**[V]**):

```
d9 25 5f 0f 23 35 4e 19 ba 73 9c cd c4 a9 17 65
```

### The one genuinely uncertain detail

The 20-byte challenge is `"CRX"` (3) + payload (16) + checksum (1). The source
documentation says to MD5 "the challenge bytes + password" without specifying
whether *challenge bytes* means the **16-byte payload** or all **20 bytes**.

`Unlock.mc` defaults to the 16-byte payload and exposes the choice as a single
constant, `Unlock.MD5_SPAN`. If the handshake fails on hardware, flip it to
`SPAN_FULL_FRAME` and retry — that is a one-line change. The connection state
machine surfaces `UNLOCK_REJECTED` so this failure is visible rather than
silent.

## Speed derivation

There is no speed characteristic. Speed comes from RPM and tire circumference,
which differs per board, so it is a user setting:

```
mph = rpm * circumference_inches * 60 / 63360
```

Defaults (**[C]**, tune against a GPS reference):

| Board | Tire | Circumference |
|---|---|---|
| XR | 11.5" Vega | 35.0" |
| Pint / Pint X | 10.5" | 32.0" |

Settings ship with the XR default. To calibrate: ride a steady speed, compare
the board reading to the watch's own GPS speed, and scale.

## Read-only rule

carve.watch **never writes** to any characteristic other than the two required
by the handshake (`f311` to request a challenge, `f3ff` to answer it). It does
not set ride mode, does not touch lights, and does not write firmware.

This is a deliberate design constraint, not an oversight. Do not add write
support for ride mode or lighting without talking to counsel first — the
manufacturer has previously brought DMCA §1201, CFAA, and trademark claims
against a third party that modified board behaviour. Reading telemetry for
interoperability and changing how the board rides are very different postures.
