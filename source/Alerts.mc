using Toybox.Attention;
using Toybox.System;
using Toybox.Lang;
using Toybox.Application.Properties;

//! Severity vocabulary, shared by the alert engine and the theme so that
//! "marginal" means the same thing to the colour picker and the buzzer.
module Alerts {
    const SEV_NONE     = 0;
    const SEV_INFO     = 1;
    const SEV_WARNING  = 2;
    const SEV_CRITICAL = 3;
}

//! Watches decoded telemetry and raises edge-triggered alerts.
//!
//! Edge-triggered matters more here than it usually does. A rider glancing at
//! a wrist at 20 mph cannot afford a buzzer that fires every second while the
//! battery sits at 19%, so each condition latches when it trips and re-arms
//! only after the value recovers past a hysteresis band.
//!
//! Priority: the loudest active condition owns the banner. Safety headroom
//! outranks battery, because running out of headroom is what puts you on the
//! ground and running out of battery only puts you on foot.
class AlertEngine {

    // Condition ids, also used as latch keys.
    static const C_HEADROOM = :headroom;
    static const C_BATTERY  = :battery;
    static const C_TEMP     = :temp;
    static const C_ERROR    = :error;
    static const C_LINK     = :link;

    private var _latched as Lang.Dictionary = {};
    private var _active as Lang.Array = [];
    private var _lastBuzzMs = 0;

    //! Never buzz twice inside this window, whatever trips. Prevents a
    //! cascade - low battery plus hot motor plus lost link - from turning into
    //! a solid wall of vibration.
    static const BUZZ_COOLDOWN_MS = 3000;

    //! Wheel RPM above which the board counts as moving. Low enough to catch
    //! a slow roll, high enough to ignore sensor jitter on a parked board.
    static const MOVING_RPM = 3;

    // Thresholds, overridable from settings.
    private var _battWarnPct = 20;
    private var _battCritPct = 10;
    private var _tempWarnC   = 60;
    private var _tempCritC   = 75;
    private var _headroomWarn = 25;
    private var _headroomCrit = 10;
    private var _alertsEnabled = true;

    function initialize() {
        reloadSettings();
    }

    function reloadSettings() {
        _battWarnPct   = intProp("battWarnPct",   20);
        _battCritPct   = intProp("battCritPct",   10);
        _tempWarnC     = intProp("tempWarnC",     60);
        _tempCritC     = intProp("tempCritC",     75);
        _headroomWarn  = intProp("headroomWarn",  25);
        _headroomCrit  = intProp("headroomCrit",  10);

        var e = Properties.getValue("alertsEnabled");
        _alertsEnabled = (e == null) ? true : e;
    }

    private function intProp(key, fallback) {
        var v = Properties.getValue(key);
        return (v == null) ? fallback : v.toNumber();
    }

    //! Re-evaluate every condition. Called once per tick.
    function evaluate(state, linkState) {
        _active = [];

        checkHeadroom(state);
        checkError(state);
        checkTemp(state);
        checkBattery(state);
        checkLink(state, linkState);
    }

    // ---- individual conditions ------------------------------------------

    //! Safety headroom is the board's own margin before it starts pushing
    //! back. It is the earliest warning available that a nosedive is coming,
    //! which is why it outranks everything else.
    //!
    //! It is only meaningful under load. A stationary board reports 0, which
    //! is indistinguishable from a genuine emergency by value alone - the
    //! first live hardware run raised a critical HEADROOM 0% alert against a
    //! board parked on a bench. Motion is what makes the reading mean
    //! anything, so the alert requires it.
    private function checkHeadroom(state) {
        var h = state.get(BoardState.HEADROOM);
        if (h == null) { return; }

        if (!isMoving(state)) {
            clear(C_HEADROOM);
            return;
        }

        if (h <= _headroomCrit) {
            raise(C_HEADROOM, Alerts.SEV_CRITICAL, "HEADROOM", h + "%");
        } else if (h <= _headroomWarn) {
            raise(C_HEADROOM, Alerts.SEV_WARNING, "HEADROOM", h + "%");
        } else if (h > _headroomWarn + 10) {
            clear(C_HEADROOM);
        }
    }

    private function checkError(state) {
        var flags = state.get(BoardState.STATUS_FLAGS);
        if (flags == null) { return; }

        // Bit 0 is the run/idle bit in every community mapping seen so far;
        // anything above it is a fault. Treated conservatively: unknown bits
        // set means something is wrong even if we cannot name it.
        var faults = flags & 0xFFFE;
        if (faults != 0) {
            raise(C_ERROR, Alerts.SEV_CRITICAL, "FAULT",
                  "0x" + faults.format("%04X"));
        } else {
            clear(C_ERROR);
        }
    }

    //! Whether the wheel is actually turning. Several board values are only
    //! interpretable under load, and a parked board should be quiet.
    private function isMoving(state) {
        var rpm = state.get(BoardState.RPM);
        return (rpm != null) && (rpm > MOVING_RPM);
    }

    private function checkTemp(state) {
        var t = state.get(BoardState.MOTOR_TEMP);
        if (t == null) { return; }

        if (t >= _tempCritC) {
            raise(C_TEMP, Alerts.SEV_CRITICAL, "MOTOR HOT", t + "C");
        } else if (t >= _tempWarnC) {
            raise(C_TEMP, Alerts.SEV_WARNING, "MOTOR WARM", t + "C");
        } else if (t < _tempWarnC - 5) {
            clear(C_TEMP);
        }
    }

    private function checkBattery(state) {
        var b = state.get(BoardState.BATTERY_PCT);
        if (b == null) { return; }

        if (b <= _battCritPct) {
            raise(C_BATTERY, Alerts.SEV_CRITICAL, "BATTERY", b + "%");
        } else if (b <= _battWarnPct) {
            raise(C_BATTERY, Alerts.SEV_WARNING, "BATTERY", b + "%");
        } else if (b > _battWarnPct + 5) {
            clear(C_BATTERY);
        }
    }

    //! A link that has gone quiet is itself an alert. Silence on this screen
    //! would otherwise be indistinguishable from a healthy board.
    private function checkLink(state, linkState) {
        if (linkState == BoardLink.STATE_UNLOCK_REJECTED) {
            raise(C_LINK, Alerts.SEV_CRITICAL, "UNLOCK FAILED", "");
        } else if (linkState == BoardLink.STATE_LIVE && !state.isLive()) {
            raise(C_LINK, Alerts.SEV_WARNING, "SIGNAL LOST", "");
        } else if (state.isLive()) {
            clear(C_LINK);
        }
    }

    // ---- latch mechanics -------------------------------------------------

    private function raise(id, severity, label, detail) {
        _active.add({ :id => id, :sev => severity, :label => label, :detail => detail });

        var previous = _latched[id];
        if (previous == null || previous < severity) {
            // New, or escalated. Escalation re-buzzes deliberately: going from
            // warning to critical is exactly when the rider needs telling.
            _latched[id] = severity;
            notify(severity);
        }
    }

    private function clear(id) {
        _latched.remove(id);
    }

    private function notify(severity) {
        if (!_alertsEnabled || severity < Alerts.SEV_WARNING) { return; }

        var now = System.getTimer();
        if (now - _lastBuzzMs < BUZZ_COOLDOWN_MS) { return; }
        _lastBuzzMs = now;

        if (Attention has :vibrate) {
            var pattern = (severity >= Alerts.SEV_CRITICAL)
                ? [ new Attention.VibeProfile(100, 400),
                    new Attention.VibeProfile(0, 150),
                    new Attention.VibeProfile(100, 400) ]
                : [ new Attention.VibeProfile(60, 250) ];
            Attention.vibrate(pattern);
        }

        if (Attention has :playTone) {
            Attention.playTone(severity >= Alerts.SEV_CRITICAL
                ? Attention.TONE_ALERT_HI
                : Attention.TONE_ALERT_LO);
        }
    }

    // ---- read side -------------------------------------------------------

    //! The single alert that should own the banner, or null when all clear.
    //! _active is built in priority order, so the first entry at the highest
    //! severity wins.
    function top() as Lang.Dictionary? {
        var best = null;
        for (var i = 0; i < _active.size(); i++) {
            var candidate = _active[i] as Lang.Dictionary;
            if (best == null || candidate[:sev] > best[:sev]) {
                best = candidate;
            }
        }
        return best;
    }

    function worstSeverity() as Lang.Number {
        var t = top();
        return (t == null) ? Alerts.SEV_NONE : t[:sev] as Lang.Number;
    }
}
