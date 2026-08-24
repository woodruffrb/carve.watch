using Toybox.BluetoothLowEnergy as Ble;
using Toybox.Lang;

//! Board GATT identifiers. See docs/PROTOCOL.md for provenance and for which
//! of these are verified versus community-reported.
module BoardUuids {

    const SERVICE_STR = "e659f300-ea98-11e3-ac10-0800200c9a66";

    // Every characteristic shares the service's suffix and differs only in the
    // third hex group, so they are stored short and expanded on demand. This
    // keeps the constant pool small, which matters on a 6X.
    const SUFFIX = "-ea98-11e3-ac10-0800200c9a66";

    // ---- telemetry -------------------------------------------------------
    const BATTERY_PCT    = "e659f303";
    const PITCH          = "e659f307";
    const ROLL           = "e659f308";
    const TRIP_ODOMETER  = "e659f30a";
    const RPM            = "e659f30b";
    const STATUS_ERROR   = "e659f30f";
    const TEMPERATURE    = "e659f310";
    const CURRENT_AMPS   = "e659f312";
    const BATTERY_VOLTS  = "e659f313";
    const SAFETY_HEADROOM= "e659f317";
    const LIFETIME_ODO   = "e659f319";
    const LAST_ERROR     = "e659f31c";

    // ---- handshake -------------------------------------------------------
    const FIRMWARE_REV   = "e659f311";
    const UART_READ      = "e659f3fe";
    const UART_WRITE     = "e659f3ff";

    //! Registration ladder. BoardLink walks it until one registers.
    //!
    //! Deliberately short. Connect IQ allows at most 3 registered profiles per
    //! app lifetime and every attempt spends one, so a long wide-to-narrow
    //! ladder defeats itself: it burns the budget and the later, narrower
    //! rungs then fail on the profile cap rather than on their width.
    //!
    //! Measured on a fenix 6X: a 34-characteristic registration is refused in
    //! silence - no throw, no callback - and a six-rung ladder ended in a
    //! blanket failure that looked like a width limit but was the attempt cap.
    //! So this starts at a width expected to succeed rather than probing down
    //! from the top.
    //!
    //! The wide contiguous sweep used for characteristic discovery is still in
    //! sweepTo(); reintroduce it only once the working ceiling is known, and
    //! never as the first attempt.
    //!
    //! Returns null past the last tier, which BoardLink treats as fatal.
    //! Widest first, because discovery is the point again.
    //!
    //! The full sweep was dropped while chasing a registration failure that
    //! turned out to be a wrong device target - so "34 characteristics is too
    //! many" was never actually tested on the right hardware and is not a
    //! finding. Registration now works, and without the sweep the raw
    //! diagnostics can only show characteristics already guessed at, which is
    //! useless for confirming a map that is mostly unverified.
    //!
    //! The timeout fallback handles a refusal, so trying wide costs a few
    //! seconds at worst.
    function tier(index as Lang.Number) as Lang.Array? {
        if (index == 0) { return sweepTo(0x20); }  // 34 - full discovery
        if (index == 1) { return sweepTo(0x13); }  // 21 - half
        if (index == 2) { return essential(); }    // 10 - app functional
        return null;
    }

    //! Last resort: the handshake pair plus the three values without which
    //! the ride screen has nothing to say.
    function minimal() as Lang.Array {
        return [
            UART_READ,
            UART_WRITE,
            FIRMWARE_REV,
            BATTERY_PCT,
            RPM,
            STATUS_ERROR
        ];
    }

    // Module scope has no `private` in Monkey C; this is internal by convention.
    function sweepTo(last as Lang.Number) as Lang.Array {
        var list = [ UART_READ, UART_WRITE ];
        for (var i = 0x01; i <= last; i++) {
            list.add("e659f3" + i.format("%02x"));
        }
        return list;
    }

    //! The minimum for normal operation: the handshake pair plus the
    //! characteristics the shipped fields actually read.
    function essential() as Lang.Array {
        return [
            UART_READ,
            UART_WRITE,
            FIRMWARE_REV,
            BATTERY_PCT,
            RPM,
            TRIP_ODOMETER,
            STATUS_ERROR,
            TEMPERATURE,
            BATTERY_VOLTS,
            SAFETY_HEADROOM
        ];
    }

    //! Short label for a characteristic, used by the raw diagnostics grid.
    //! "e659f30b" renders as "0b".
    function shortLabel(uuidShort as Lang.String) as Lang.String {
        return uuidShort.substring(6, 8);
    }

    //! Characteristics we subscribe to rather than poll.
    //!
    //! Every telemetry characteristic on the board is NOTIFY+READ+WRITE with a
    //! CCCD, confirmed by GATT dump - so this split is a resource decision,
    //! not a capability limit. These three change fastest and are worth the
    //! subscription; the rest are read on the tick to keep the number of
    //! CCCD writes at connect time small and bound notification traffic.
    function notifyCharacteristics() as Lang.Array {
        return [ BATTERY_PCT, RPM, STATUS_ERROR ];
    }

    function uuid(shortForm) {
        return Ble.stringToUuid(shortForm + SUFFIX);
    }

    function serviceUuid() {
        return Ble.stringToUuid(SERVICE_STR);
    }
}
