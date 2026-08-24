using Toybox.System;
using Toybox.Lang;
using Toybox.Application.Properties;

//! Decoded board telemetry plus the freshness bookkeeping that decides
//! whether any of it can still be trusted.
//!
//! Values live in a dictionary keyed by symbol rather than as named fields.
//! That is what lets Fields.mc treat a metric as data - a user-selectable
//! field is just a symbol - instead of needing a switch arm per metric.
//!
//! Every write stamps a timestamp. Nothing in the UI reads a value without
//! going through isFresh(), because a frozen number on a speed display is
//! worse than a blank one.
class BoardState {

    // Metric keys. These are the same symbols Fields.mc binds to.
    static const BATTERY_PCT   = :batteryPct;
    static const RPM           = :rpm;
    static const TRIP_M        = :tripMeters;
    static const LIFETIME_M    = :lifetimeMeters;
    static const MOTOR_TEMP    = :motorTempC;
    static const BATTERY_V     = :batteryVolts;
    static const HEADROOM      = :safetyHeadroom;
    static const STATUS_FLAGS  = :statusFlags;
    static const LAST_ERROR    = :lastErrorCode;
    static const FIRMWARE      = :firmwareRev;

    var connected = false;
    var unlocked  = false;
    var rssi      = null;

    private var _values as Lang.Dictionary = {};
    private var _stamps as Lang.Dictionary = {};
    private var _circumferenceIn = 35.0;

    //! A value older than this is rendered as "--" rather than as a stale
    //! number. Four seconds is comfortably longer than the 1 Hz poll but
    //! short enough that a dropped link shows up before it matters.
    static const FRESH_WINDOW_MS = 4000;

    function initialize() {
        reloadSettings();
    }

    function reloadSettings() {
        var v = Properties.getValue("tireCircumferenceIn");
        if (v != null && v > 0) {
            _circumferenceIn = v.toFloat();
        }
    }

    function put(key, value) {
        _values[key] = value;
        _stamps[key] = System.getTimer();
    }

    //! Raw value regardless of age. Only the staleness logic and the
    //! diagnostics dump should use this; everything else wants get().
    function peek(key) {
        return _values[key];
    }

    //! Value, or null if it has gone stale.
    function get(key) {
        return isFresh(key) ? _values[key] : null;
    }

    function isFresh(key) {
        var t = _stamps[key];
        if (t == null) { return false; }
        return (System.getTimer() - t) < FRESH_WINDOW_MS;
    }

    //! Ground speed in metres per second, derived from wheel RPM.
    //!
    //! The board exposes no speed characteristic, and this beats GPS speed for
    //! this use case - GPS lags through tight carves and drops under tree
    //! cover. Accuracy rides entirely on the tire circumference setting; see
    //! docs/PROTOCOL.md for the calibration procedure.
    function speedMps() {
        var r = get(RPM);
        if (r == null) { return null; }
        return (r * _circumferenceIn * 0.0254) / 60.0;
    }

    //! Whether telemetry is actually arriving. Deliberately distinct from
    //! `connected`: the GATT link can be up while the unlock has lapsed,
    //! which leaves the characteristics readable but frozen at their last
    //! values. That state must not look healthy.
    //! Live means telemetry is actually arriving. `unlocked` is deliberately
    //! not required: older firmware has no handshake to complete, and gating
    //! on it would report a perfectly healthy board as dead.
    function isLive() {
        return connected && isFresh(RPM);
    }

    //! Whether the board is actually reporting, as opposed to returning the
    //! zeros a locked board gives out.
    //!
    //! A locked board answers identity reads - serial, firmware, hardware
    //! revision - while zeroing every live value. Treating that as data
    //! produced a critical low-battery alert against a board reading 0%, which
    //! buzzed the watch every few seconds. No real board reports both zero
    //! charge and zero pack voltage.
    function hasPlausibleTelemetry() {
        var b = peek(BATTERY_PCT);
        var v = peek(BATTERY_V);
        if (b != null && b > 0) { return true; }
        if (v != null && v > 0) { return true; }
        return false;
    }

    function clearTelemetry() {
        _values = {};
        _stamps = {};
        _raw = {};
        _rawChanged = {};
    }

    // =====================================================================
    // Raw store - diagnostics only
    // =====================================================================
    //
    // Keeps the undecoded bytes for every characteristic that registered,
    // including ones with no known meaning. This is what lets Diagnostics
    // identify a value by behaviour: spin the wheel, see which cell moves.
    //
    // Deliberately separate from the decoded store. Decoded values are what
    // the app believes; these are what the board actually said, and the whole
    // point is being able to tell those apart when a guess is wrong.

    //! How long a value stays flagged as recently-changed. Long enough to
    //! catch it after looking down at the watch, short enough that it settles.
    static const CHANGE_HIGHLIGHT_MS = 3000;

    private var _raw as Lang.Dictionary = {};
    private var _rawChanged as Lang.Dictionary = {};

    function putRaw(shortForm as Lang.String, bytes as Lang.ByteArray) as Void {
        var prev = _raw[shortForm];
        if (prev == null || !bytesEqual(prev, bytes)) {
            _rawChanged[shortForm] = System.getTimer();
        }
        _raw[shortForm] = bytes;
    }

    function getRaw(shortForm as Lang.String) as Lang.ByteArray? {
        return _raw[shortForm];
    }

    //! True if this characteristic's bytes changed in the last few seconds.
    function rawChangedRecently(shortForm as Lang.String) as Lang.Boolean {
        var t = _rawChanged[shortForm];
        if (t == null) { return false; }
        return (System.getTimer() - t) < CHANGE_HIGHLIGHT_MS;
    }

    private function bytesEqual(a as Lang.ByteArray?, b as Lang.ByteArray?) as Lang.Boolean {
        if (a == null || b == null) { return false; }
        if (a.size() != b.size()) { return false; }
        for (var i = 0; i < a.size(); i++) {
            if (a[i] != b[i]) { return false; }
        }
        return true;
    }

    function allKeys() {
        return _values.keys();
    }
}
