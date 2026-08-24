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

    //! Registration tiers, widest first.
    //!
    //! Connect IQ caps how much can be registered and the exact limit is
    //! undocumented, so rather than guess a safe number, BoardLink tries these
    //! in order and falls back on failure. Tier 0 sweeps the board's entire
    //! characteristic range, which is what lets Diagnostics identify a value
    //! by behaviour when a UUID guess is wrong. Tier 2 is the minimum the
    //! shipped field set needs.
    //!
    //! A descending ladder. BoardLink walks it until one registers.
    //!
    //! The top rungs are contiguous sweeps for discovery - they let
    //! Diagnostics identify a characteristic by behaviour. The lower rungs
    //! switch to the specific non-contiguous set the app needs, because a
    //! narrow contiguous sweep would exclude RPM, status and headroom and
    //! leave the app connected but useless.
    //!
    //! Measured on hardware: 34 characteristics is silently refused by a
    //! fenix 6X - no throw, no callback. The real limit is discovered by
    //! walking down, and whichever rung sticks is shown on Diagnostics page 1,
    //! so the ceiling gets recorded rather than guessed at.
    //!
    //! Returns null past the last tier, which BoardLink treats as fatal.
    function tier(index as Lang.Number) as Lang.Array? {
        if (index == 0) { return sweepTo(0x20); }   // 34 - full discovery
        if (index == 1) { return sweepTo(0x16); }   // 24
        if (index == 2) { return sweepTo(0x0e); }   // 16
        if (index == 3) { return sweepTo(0x0a); }   // 12
        if (index == 4) { return essential(); }     // 10 - app functional
        if (index == 5) { return minimal(); }       //  6 - handshake + core
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
