using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.System;
using Toybox.Application.Properties;
using Toybox.Lang;

//! The ride screen.
//!
//! Drawn with dc primitives rather than a layout XML resource. That is a
//! deliberate trade: XML layouts bind a fixed widget to a fixed position, and
//! this screen's whole point is that any slot can show any metric. Computing
//! positions from dc dimensions also means one implementation covers 218 px
//! through 454 px round displays without a resource fork per size.
//!
//! Everything is laid out in fractions of screen size, never in pixels.
class RideView extends WatchUi.View {

    private var _link;
    private var _alerts;

    // Slot assignments, read from settings.
    private var _slotPrimary   = Fields.F_SPEED;
    private var _slotLeft      = Fields.F_BATTERY;
    private var _slotRight     = Fields.F_TRIP;
    private var _slotBottom    = Fields.F_RIDE_TIME;
    private var _showArc       = true;

    function initialize(link, alerts) {
        View.initialize();
        _link = link;
        _alerts = alerts;
        reloadSettings();
    }

    function reloadSettings() {
        _slotPrimary = intProp("slotPrimary", Fields.F_SPEED);
        _slotLeft    = intProp("slotLeft",    Fields.F_BATTERY);
        _slotRight   = intProp("slotRight",   Fields.F_TRIP);
        _slotBottom  = intProp("slotBottom",  Fields.F_RIDE_TIME);

        var arc = Properties.getValue("showBatteryArc");
        _showArc = (arc == null) ? true : arc;
    }

    private function intProp(key, fallback) {
        var v = Properties.getValue(key);
        return (v == null) ? fallback : v.toNumber();
    }

    function onLayout(dc) {}

    function onShow() {
        Theme.lowPower = false;
    }

    function onUpdate(dc) {
        var state = _link.getBoardState();
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Graphics.COLOR_TRANSPARENT, Theme.bg);
        dc.clear();

        // AMOLED always-on: sparse, dim, and nothing large or static enough to
        // burn. MIP never takes this path - dimming a reflective panel makes
        // it strictly harder to read and saves nothing.
        if (Theme.shouldProtectDisplay()) {
            drawLowPower(dc, state, w, h);
            return;
        }

        if (_showArc) {
            drawBatteryArc(dc, state, w, h);
        }

        var alert = _alerts.top();
        if (alert != null) {
            drawAlertBanner(dc, alert, w, h);
        } else {
            drawLinkStatus(dc, state, w, h);
        }

        drawPrimary(dc, state, w, h);
        drawSecondaryRow(dc, state, w, h);
        drawBottom(dc, state, w, h);
    }

    // =====================================================================
    // Components
    // =====================================================================

    //! Board state of charge as an arc around the bezel. Chosen over a bar
    //! because on a round display the bezel is the one region that costs no
    //! centre space, and peripheral vision reads arc length without focus -
    //! which is the whole point while moving.
    private function drawBatteryArc(dc, state, w, h) {
        var pct = state.get(BoardState.BATTERY_PCT);
        var cx = w / 2;
        var cy = h / 2;
        var r = (w / 2) - 4;

        dc.setPenWidth(6);

        // Track.
        dc.setColor(Theme.border, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, 210, 330);

        if (pct == null) { return; }

        // Angles are counter-clockwise from 3 o'clock, so drawing clockwise
        // from 210 deg runs 210 -> 180 -> 90 -> 0 -> 330: the top 240 deg of
        // the bezel, filling left to right. The wrap past zero has to be
        // normalised back into 0..360 rather than passed as a negative.
        var sweep = 240.0 * (pct / 100.0);
        var end = 210 - sweep;
        if (end < 0) { end += 360; }

        var color = Theme.text;
        if (pct <= 10)      { color = Theme.danger; }
        else if (pct <= 20) { color = Theme.warn; }
        else                { color = Theme.ok; }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, 210, end);
        dc.setPenWidth(1);
    }

    //! The banner takes the top strip whenever anything is wrong. It is the
    //! only element allowed a filled background, because a coloured block is
    //! readable at a glance in a way that coloured text is not.
    private function drawAlertBanner(dc, alert as Lang.Dictionary, w, h) {
        var sev = alert[:sev];
        var bg = (sev >= Alerts.SEV_CRITICAL) ? Theme.danger : Theme.warn;
        var fg = (sev >= Alerts.SEV_CRITICAL) ? 0xFFFFFF : 0x000000;

        // fillRectangle wants integers; the fractional layout has to be
        // rounded before it gets there.
        var top = (h * 0.13).toNumber();
        var bandH = (h * 0.15).toNumber();

        dc.setColor(bg, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, top, w, bandH);

        var text = alert[:label] as Lang.String;
        var detail = alert[:detail] as Lang.String;
        if (detail != null && !detail.equals("")) {
            text = text + " " + detail;
        }

        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, top + bandH / 2, Graphics.FONT_TINY, text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Connection state, shown only when there is no alert competing for the
    //! strip. Says nothing at all once the link is healthy - a permanent
    //! "connected" badge is noise the rider learns to ignore.
    private function drawLinkStatus(dc, state, w, h) {
        var msg = null;
        var color = Theme.textMuted;

        switch (_link.getState()) {
            case BoardLink.STATE_SCANNING:
                msg = "SEARCHING"; break;
            case BoardLink.STATE_CONNECTING:
                msg = "CONNECTING"; break;
            case BoardLink.STATE_UNLOCKING:
                msg = "HANDSHAKE"; break;
            case BoardLink.STATE_PROFILE_FAILED:
                // Deliberately not inferring a cause here. phoneConnected only
                // reports whether a phone is paired - it is false whenever the
                // phone's own radio is off, which says nothing about the
                // watch's. An earlier build read it as "radio off" and told
                // users to check a setting that was already correct.
                msg = "BLE ERROR";
                color = Theme.danger;
                break;
            case BoardLink.STATE_IDLE:
                msg = "OFFLINE"; break;
        }
        if (msg == null) { return; }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.17, Graphics.FONT_XTINY, msg,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! The one number the rider actually looks at, set as large as the display
    //! allows.
    //!
    //! The unit is tucked to the right of the digits rather than under them.
    //! Stacked underneath it lands close enough to the secondary row's labels
    //! to read as part of that row, and it costs vertical space the layout
    //! does not have between a 72 px numeral and the field row below it.
    private function drawPrimary(dc, state, w, h) {
        var value = Fields.value(_slotPrimary, state);
        var unit  = Fields.units(_slotPrimary);
        var cy = h * 0.44;

        dc.setColor(Theme.severityColor(Fields.severity(_slotPrimary, state)),
                    Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, cy, Graphics.FONT_NUMBER_THAI_HOT, value,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        if (!unit.equals("")) {
            // Measured, not assumed: the digit count changes with speed, and
            // a fixed offset would drift off the numeral as it grows.
            var half = dc.getTextWidthInPixels(value, Graphics.FONT_NUMBER_THAI_HOT) / 2;
            var unitW = dc.getTextWidthInPixels(unit, Graphics.FONT_XTINY);
            var x = (w / 2) + half + (w * 0.02);

            // A wide value - three-digit RPM, or km/h at speed - would push
            // the unit past the right edge. Clamp so it stays on the glass;
            // slight overlap with the numeral beats clipping the text.
            var maxX = w - unitW - (w * 0.04);
            if (x > maxX) { x = maxX; }

            dc.setColor(Theme.textMuted, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, cy + (h * 0.07), Graphics.FONT_XTINY, unit,
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    private function drawSecondaryRow(dc, state, w, h) {
        drawSlot(dc, state, _slotLeft,  w * 0.27, h * 0.68, h,
                 Graphics.FONT_NUMBER_MILD);
        drawSlot(dc, state, _slotRight, w * 0.73, h * 0.68, h,
                 Graphics.FONT_NUMBER_MILD);
    }

    //! The bottom slot is tertiary, and gets a smaller font to say so. At
    //! FONT_NUMBER_MILD it competes with the secondary row for attention and
    //! crowds it on a 280 px face.
    private function drawBottom(dc, state, w, h) {
        if (_slotBottom == Fields.F_EMPTY) { return; }
        drawSlot(dc, state, _slotBottom, w * 0.5, h * 0.875, h,
                 Graphics.FONT_TINY);
    }

    //! One label-over-value pair. Label above rather than below so that the
    //! values across a row share a baseline and scan horizontally.
    //!
    //! Offsets are fractions of screen height, not fixed pixels - a 14 px gap
    //! that looks right on a 280 px face is proportionally half again as large
    //! on a 218 px one.
    private function drawSlot(dc, state, fieldId, cx, cy, h, valueFont) {
        if (fieldId == Fields.F_EMPTY) { return; }

        var labelGap = h * 0.05;
        var valueGap = h * 0.03;

        dc.setColor(Theme.textMuted, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - labelGap, Graphics.FONT_XTINY, Fields.label(fieldId),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(Theme.severityColor(Fields.severity(fieldId, state)),
                    Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + valueGap, valueFont,
            Fields.value(fieldId, state),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Always-on state for burn-in-prone displays: speed and battery only, at
    //! half brightness, nudged off-centre so successive frames do not land on
    //! identical pixels.
    private function drawLowPower(dc, state, w, h) {
        var jitter = (System.getTimer() / 60000) % 3;

        dc.setColor(Theme.dim(Theme.text), Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, (h * 0.45) + jitter, Graphics.FONT_NUMBER_HOT,
            Fields.value(_slotPrimary, state),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var pct = state.get(BoardState.BATTERY_PCT);
        if (pct != null) {
            dc.setColor(Theme.dim(Theme.textMuted), Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, (h * 0.62) + jitter, Graphics.FONT_XTINY,
                pct.format("%d") + "%",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }
}
