using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.System;
using Toybox.Lang;

//! Raw telemetry dump.
//!
//! This exists because most of the characteristic map in docs/PROTOCOL.md is
//! community-reported rather than verified on hardware. Decoded numbers that
//! look plausible but are wrong - a byte order flipped, a scale factor off by
//! ten - are hard to catch on the ride screen and obvious here, next to the
//! link state that produced them.
//!
//! Keep it: the map will need re-verifying every time board firmware moves.
class DiagnosticsView extends WatchUi.View {

    private var _link;

    // Everything worth seeing at once, in the order it is useful.
    private var _rows as Lang.Array = [
        [ "fw",    BoardState.FIRMWARE     ],
        [ "batt",  BoardState.BATTERY_PCT  ],
        [ "rpm",   BoardState.RPM          ],
        [ "trip",  BoardState.TRIP_M       ],
        [ "temp",  BoardState.MOTOR_TEMP   ],
        [ "volt",  BoardState.BATTERY_V    ],
        [ "head",  BoardState.HEADROOM     ],
        [ "stat",  BoardState.STATUS_FLAGS ]
    ];

    function initialize(link) {
        View.initialize();
        _link = link;
    }

    function onUpdate(dc) {
        var state = _link.getBoardState();
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Graphics.COLOR_TRANSPARENT, Theme.bg);
        dc.clear();

        dc.setColor(Theme.accent, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.10, Graphics.FONT_XTINY,
            linkStateName() + "  rssi " + fmt(state.rssi),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Two columns so eight rows fit without scrolling on a 240 px display.
        var top = h * 0.24;
        var rowH = (h * 0.66) / 4;

        for (var i = 0; i < _rows.size(); i++) {
            var col = i / 4;
            var row = i % 4;
            var cx = (col == 0) ? (w * 0.29) : (w * 0.71);
            var cy = top + (row * rowH);

            var rowDef = _rows[i] as Lang.Array;

            dc.setColor(Theme.textMuted, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, cy, Graphics.FONT_XTINY, rowDef[0],
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // peek() rather than get(): staleness is exactly what is being
            // diagnosed here, so a stale value must still be visible.
            var raw = state.peek(rowDef[1]);
            dc.setColor(state.isFresh(rowDef[1]) ? Theme.text : Theme.textMuted,
                        Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, cy + rowH * 0.42, Graphics.FONT_XTINY, fmt(raw),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    private function fmt(v) {
        if (v == null) { return "-"; }
        if (v instanceof Lang.Float || v instanceof Lang.Double) {
            return v.format("%.1f");
        }
        return v.toString();
    }

    private function linkStateName() {
        switch (_link.getState()) {
            case BoardLink.STATE_IDLE:            return "idle";
            case BoardLink.STATE_SCANNING:        return "scan";
            case BoardLink.STATE_CONNECTING:      return "conn";
            case BoardLink.STATE_UNLOCKING:       return "shake";
            case BoardLink.STATE_LIVE:            return "live";
            case BoardLink.STATE_PROFILE_FAILED:  return "profile-fail";
            case BoardLink.STATE_UNLOCK_REJECTED: return "unlock-fail";
        }
        return "?";
    }
}

class DiagnosticsDelegate extends WatchUi.BehaviorDelegate {
    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
