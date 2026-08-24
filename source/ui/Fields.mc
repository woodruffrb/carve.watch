using Toybox.System;
using Toybox.Activity;
using Toybox.Time;
using Toybox.Lang;

//! The customisable field registry.
//!
//! A "field" is a small descriptor - id, label, and a function that turns the
//! current state into a formatted string plus a severity. The layout asks for
//! whichever field id a slot is configured to show, so adding a metric is a
//! matter of appending one entry here and one <listEntry> to settings.xml.
//! No layout code changes.
//!
//! Ids are stable and stored in user settings. Never renumber them; append.
module Fields {

    const F_EMPTY        = 0;
    const F_SPEED        = 1;
    const F_BATTERY      = 2;
    const F_TRIP         = 3;
    const F_MOTOR_TEMP   = 4;
    const F_BATTERY_V    = 5;
    const F_HEADROOM     = 6;
    const F_RIDE_TIME    = 7;
    const F_MAX_SPEED    = 8;
    const F_AVG_SPEED    = 9;
    const F_WATCH_BATT   = 10;
    const F_CLOCK        = 11;
    const F_HEART_RATE   = 12;
    const F_RPM          = 13;

    const BLANK = "--";

    //! Session-scoped derived values that no single characteristic provides.
    //! Owned here because they are presentation concerns, not board state.
    var maxSpeedMps = 0.0;
    var speedSumMps = 0.0;
    var speedSamples = 0;
    var rideStartMs = null;

    function resetSession() {
        maxSpeedMps = 0.0;
        speedSumMps = 0.0;
        speedSamples = 0;
        rideStartMs = System.getTimer();
    }

    //! Fold the current sample into the session aggregates. Called once per
    //! tick, and only while the link is live so that a dropout does not drag
    //! the average toward zero.
    function accumulate(state) {
        var v = state.speedMps();
        if (v == null) { return; }
        if (v > maxSpeedMps) { maxSpeedMps = v; }
        speedSumMps += v;
        speedSamples++;
    }

    function label(id) {
        switch (id) {
            case F_SPEED:      return "SPEED";
            case F_BATTERY:    return "BATT";
            case F_TRIP:       return "TRIP";
            case F_MOTOR_TEMP: return "MOTOR";
            case F_BATTERY_V:  return "VOLTS";
            case F_HEADROOM:   return "HEADROOM";
            case F_RIDE_TIME:  return "TIME";
            case F_MAX_SPEED:  return "MAX";
            case F_AVG_SPEED:  return "AVG";
            case F_WATCH_BATT: return "WATCH";
            case F_CLOCK:      return "CLOCK";
            case F_HEART_RATE: return "HR";
            case F_RPM:        return "RPM";
        }
        return "";
    }

    //! Formatted value for a field. Returns BLANK rather than a stale number
    //! whenever the underlying telemetry has aged out.
    function value(id, state) {
        switch (id) {
            case F_SPEED:      return fmtSpeed(state.speedMps());
            case F_MAX_SPEED:  return fmtSpeed(maxSpeedMps);
            case F_AVG_SPEED:  return fmtSpeed(avgSpeedMps());
            case F_BATTERY:    return fmtInt(state.get(BoardState.BATTERY_PCT));
            case F_TRIP:       return fmtDistance(state.tripMeters());
            case F_MOTOR_TEMP: return fmtTemp(state.get(BoardState.MOTOR_TEMP));
            case F_BATTERY_V:  return fmtFloat(state.get(BoardState.BATTERY_V), 1);
            case F_HEADROOM:   return fmtInt(state.get(BoardState.HEADROOM));
            case F_RPM:        return fmtInt(state.get(BoardState.RPM));
            case F_RIDE_TIME:  return fmtDuration();
            case F_WATCH_BATT: return fmtInt(System.getSystemStats().battery.toNumber());
            case F_CLOCK:      return fmtClock();
            case F_HEART_RATE: return fmtHeartRate();
        }
        return BLANK;
    }

    function units(id) {
        var settings = System.getDeviceSettings();
        var statute = (settings.distanceUnits == System.UNIT_STATUTE);

        switch (id) {
            case F_SPEED:
            case F_MAX_SPEED:
            case F_AVG_SPEED:  return statute ? "mph" : "km/h";
            case F_TRIP:       return statute ? "mi" : "km";
            case F_BATTERY:
            case F_HEADROOM:
            case F_WATCH_BATT: return "%";
            case F_MOTOR_TEMP: return "C";
            case F_BATTERY_V:  return "V";
            case F_HEART_RATE: return "bpm";
        }
        return "";
    }

    //! Per-field severity, so a slot can colour itself without the view
    //! needing to know what it is displaying.
    function severity(id, state) {
        switch (id) {
            case F_BATTERY: {
                var b = state.get(BoardState.BATTERY_PCT);
                if (b == null) { return Alerts.SEV_NONE; }
                if (b <= 10) { return Alerts.SEV_CRITICAL; }
                if (b <= 20) { return Alerts.SEV_WARNING; }
                break;
            }
            case F_HEADROOM: {
                var h = state.get(BoardState.HEADROOM);
                if (h == null) { return Alerts.SEV_NONE; }
                // Same reasoning as the headroom alert: meaningless at rest,
                // so do not paint a parked board's field red.
                var rpm = state.get(BoardState.RPM);
                if (rpm == null || rpm <= 3) { return Alerts.SEV_NONE; }
                if (h <= 10) { return Alerts.SEV_CRITICAL; }
                if (h <= 25) { return Alerts.SEV_WARNING; }
                break;
            }
            case F_MOTOR_TEMP: {
                var t = state.get(BoardState.MOTOR_TEMP);
                if (t == null) { return Alerts.SEV_NONE; }
                if (t >= 75) { return Alerts.SEV_CRITICAL; }
                if (t >= 60) { return Alerts.SEV_WARNING; }
                break;
            }
        }
        return Alerts.SEV_NONE;
    }

    // ---- formatters ------------------------------------------------------

    function avgSpeedMps() {
        if (speedSamples == 0) { return null; }
        return speedSumMps / speedSamples;
    }

    function fmtSpeed(mps) {
        if (mps == null) { return BLANK; }
        var settings = System.getDeviceSettings();
        var v = (settings.distanceUnits == System.UNIT_STATUTE)
            ? mps * 2.23694
            : mps * 3.6;
        return v.format("%.1f");
    }

    function fmtDistance(meters) {
        if (meters == null) { return BLANK; }
        var settings = System.getDeviceSettings();
        var v = (settings.distanceUnits == System.UNIT_STATUTE)
            ? meters / 1609.344
            : meters / 1000.0;
        return v.format("%.2f");
    }

    function fmtTemp(celsius) {
        if (celsius == null) { return BLANK; }
        return celsius.format("%d");
    }

    function fmtInt(v) {
        return (v == null) ? BLANK : v.format("%d");
    }

    function fmtFloat(v, places) {
        if (v == null) { return BLANK; }
        return v.format("%." + places.format("%d") + "f");
    }

    function fmtDuration() {
        if (rideStartMs == null) { return BLANK; }
        var secs = (System.getTimer() - rideStartMs) / 1000;
        var h = secs / 3600;
        var m = (secs % 3600) / 60;
        var s = secs % 60;
        if (h > 0) {
            return h.format("%d") + ":" + m.format("%02d") + ":" + s.format("%02d");
        }
        return m.format("%d") + ":" + s.format("%02d");
    }

    function fmtClock() {
        var now = System.getClockTime();
        var hour = now.hour;
        if (!System.getDeviceSettings().is24Hour) {
            hour = hour % 12;
            if (hour == 0) { hour = 12; }
        }
        return hour.format("%d") + ":" + now.min.format("%02d");
    }

    function fmtHeartRate() {
        var info = Activity.getActivityInfo();
        if (info == null || info.currentHeartRate == null) { return BLANK; }
        return info.currentHeartRate.format("%d");
    }
}
