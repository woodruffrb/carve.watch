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

## Build for the right device - this cost a full debugging session

The reference watch is a **fenix 6 Sapphire**, which is product ID
**`fenix6pro`**, not `fenix6xpro`. Confirmed from `GarminDevice.xml`:

```
<Description>fenix 6 Sapphire</Description>
<PartNumber>006-B3290-00</PartNumber>
<VmVersion>3.4.5</VmVersion>
```

The SDK maps part numbers unambiguously:

| Part number | Product ID | Covers |
|---|---|---|
| `006-B3290-00` | `fenix6pro` | fenix 6 Pro / **6 Sapphire** / 6 Pro Solar |
| `006-B3291-00` | `fenix6xpro` | fenix 6X Pro / 6X Sapphire / tactix Delta |

A `.prg` built for `fenix6xpro` **installs and runs on a `fenix6pro`**. The
Monkey C executes, the UI renders at correct proportions because the layout
is computed from `dc` dimensions - and the BLE layer silently does nothing.
Every call is accepted, no exception is thrown, and no callback is ever
delivered.

That failure mode is indistinguishable from a broken profile definition,
and an entire session was spent chasing it: characteristic count, profile
budget, descriptor lists, radio state, stale app UUID metadata, and
registration timing were each investigated and eliminated. Garmin's own
NordicThingy52 sample, built for the same wrong target, failed identically -
which correctly proved the fault was not in this app, but did not reveal
why.

**Verify the target before debugging BLE.** Read `GarminDevice.xml` from the
watch root and match `PartNumber` against the SDK device definitions in
`%APPDATA%/Garmin/ConnectIQ/Devices/*/`. Do not take the model from memory
or from what the watch is called colloquially.

Both `fenix6pro` and `fenix6xpro` do declare `BluetoothLowEnergy` support,
so there is no capability difference here - only a wrong binary.

## Before debugging anything on the watch

**The board accepts only one BLE connection.** The phone must not be holding
it, so turn the *phone's* Bluetooth off or force-quit the board app. The
*watch's* Bluetooth is a separate thing and must stay on.

Be careful reading `phoneConnected` as a proxy for the watch radio: it is
false whenever no phone is paired, which is the normal state once the phone's
own radio is off. It does not indicate anything about the watch's radio, and
an earlier build wrongly told users to "CHECK BT" on the strength of it.

Diagnostics page 1 shows `ble conn`, from `getAvailableConnectionCount()`.
That is a direct probe of the BLE subsystem: a number means BLE is up and any
fault is in the profile definition; `err` means the subsystem itself is
refusing, which is a different problem entirely.

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

### Verified on hardware, byte for byte

Captured from a fenix 6 Sapphire talking to a board on firmware 4165:

```
challenge  09 8E 56 6D 05 3B 63 6D C9 A7 20 04 55 29 80 19 80 5A A7 5E
response   09 8E 56 36 BD BD 95 D7 F1 14 61 F7 C7 4E C3 FC 13 4B CF F7
```

The response matches the reference algorithm exactly. Note the challenge is
**constant** across sessions on this board - the same twenty bytes appeared
in captures minutes apart - so the first three bytes are not a random nonce
prefix and are best understood as fixed for a given board.

### The full sequence, from a working client

Taken from a reference Python client rather than from prose about it:

1. Subscribe to the UART read characteristic
2. Read the firmware revision
3. Write the firmware revision back - this provokes the challenge
4. Wait for the 20-byte challenge on the UART notification
5. Write `challenge[0..2] ++ MD5(challenge[3..18] ++ key) ++ xor` to UART write
6. **Unsubscribe from the UART read characteristic**
7. Wait ~0.5 s, then read telemetry

**Step 6 is easy to miss and it matters.** Success is never acknowledged -
you write, stop listening, pause, and read. Leaving the subscription open
and re-provoking a fresh challenge on a timer tears the unlock down as fast
as it is established; hammering the handshake prevents the handshake.

Only re-run the sequence if telemetry fails to appear after the settle
window, and re-subscribe as part of doing so.

### Firmware and whether the handshake is needed at all

The challenge-response arrived with the **Gemini** firmware. The reference
board here reports `0x1045` = **4165**, which predates it, so it is not
certain this board requires an unlock at all - the 20-byte UART frames may
not be gating telemetry the way they do on Gemini and later.

Do not assume the handshake is the reason telemetry is missing until the
sequence above has been run correctly, including step 6.

### A locked board reads zero

Confirmed on hardware. With the handshake incomplete, every telemetry
characteristic reads `0000` while the identity values answer normally:

| Short | Value | Meaning |
|---|---|---|
| `01` | `b276` | serial |
| `11` | `1045` | firmware revision (4165) |
| `18` | `1073` | hardware revision |
| `20` | `0001` | unknown, static |
| everything else | `0000` | zeroed until unlocked |

Two consequences.

**Zeros are not data.** Alerting on them produced a critical low-battery
warning against a board reading 0%, buzzing the watch every few seconds.
`BoardState.hasPlausibleTelemetry()` gates the alert engine: no real board
reports both zero charge and zero pack voltage.

**Identity reads succeeding proves nothing about the unlock.** Serial and
firmware answer on a locked board, so a successful read - or a successful
write of the response - is not evidence the handshake took. Only live
telemetry appearing is.

### Write the response acknowledged

`e659f3ff` advertises property `WRITE`, not `WRITE NO RESPONSE`, so it wants
an acknowledged write. Connect IQ's `WRITE_TYPE_DEFAULT` is the
unacknowledged form; use `WRITE_TYPE_WITH_RESPONSE`. A board that requires
acknowledgement will discard a byte-perfect response silently otherwise.

### Detecting success

**A successful response write is the proof, not an incoming notification.**

The board does not necessarily push its telemetry characteristics. Reads
work and the UART subscription works, but waiting for a telemetry
notification to confirm the unlock meant a provably correct response was
read as a failure, and the app re-challenged indefinitely while sending
byte-perfect answers. Treat `onCharacteristicWrite` on the UART write
characteristic, with a success status, as the handshake completing - then
poll.

### Response format - verified against the reference implementation

The response's first three bytes are **the challenge's own first three bytes,
echoed back**. They are not a literal `CRX`.

Every write-up describes them as a signature, because on boards whose
challenge begins `43 52 58` the echo and the literal are indistinguishable.
The reference board's challenge begins `09 8E 56`, and hardcoding `CRX`
produced sixteen correctly-hashed responses that the board rejected outright.

From the reference implementation:

```javascript
const appendix = [0xd9, 0x25, 0x5f, 0x0f, 0x23, 0x35, 0x4e, 0x19,
                  0xba, 0x73, 0x9c, 0xcd, 0xc4, 0xa9, 0x17, 0x65];
const password = [...challenge.slice(3, -1), ...appendix];
const response = [...challenge.slice(0, 3), ...md5(password)];
// then push XOR of all response bytes
```

So, precisely:

| Part | Bytes | Source |
|---|---|---|
| prefix | 0..2 | `challenge[0..2]`, echoed |
| digest | 3..18 | `MD5(challenge[3..18] ++ key)` |
| checksum | 19 | XOR of response bytes 0..18 |

`slice(3, -1)` is bytes 3 through 18 - sixteen bytes, excluding the trailing
checksum - hashed **before** the key.

**Read the reference implementations, not summaries of them.** This project
lost a long debugging session to a summarised README that described the
prefix as a signature. Several mature open-source clients implement this
protocol correctly; when something does not work, read their source.

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
