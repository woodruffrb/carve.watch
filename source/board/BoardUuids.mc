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

    //! Characteristics registered with the BLE profile.
    //!
    //! Connect IQ caps how much can be registered, and every entry costs
    //! memory whether or not it is subscribed. This is the deliberate minimum
    //! for the shipped field set plus the handshake - if you add a field to
    //! Fields.mc that needs a new characteristic, add it here too, then
    //! re-test on hardware. Registration failure surfaces as
    //! BoardLink.STATE_PROFILE_FAILED rather than a silent dead connection.
    function registeredCharacteristics() as Lang.Array {
        return [
            FIRMWARE_REV,
            UART_READ,
            UART_WRITE,
            BATTERY_PCT,
            RPM,
            TRIP_ODOMETER,
            STATUS_ERROR,
            TEMPERATURE,
            BATTERY_VOLTS,
            SAFETY_HEADROOM
        ];
    }

    //! Characteristics that push updates. Everything else is polled on the
    //! 1 Hz tick, because subscribing to all of them at once exceeds what the
    //! board reliably delivers.
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
