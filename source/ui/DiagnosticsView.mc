using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.System;
using Toybox.Lang;

//! On-device protocol diagnostics.
//!
//! This exists because most of the characteristic map is community-reported
//! rather than confirmed, and because Connect IQ cannot discover a
//! characteristic it did not register in advance - so the watch cannot go
//! looking for the right UUID on its own. What it can do is register the
//! board's whole range and show the raw bytes, which turns identification
//! into something done by behaviour rather than by guesswork:
//!
//!   Spin the wheel. Watch which cell lights up. That one is RPM.
//!
//! Page 1 is the link and handshake. Pages 2+ are the raw sweep. UP/DOWN
//! pages. Values that changed in the last few seconds render in the accent
//! colour, which is the whole trick.
class DiagnosticsView extends WatchUi.View {

    private var _link;
    private var _page = 0;

    // Raw grid geometry: two columns, four rows per page.
    static const ROWS = 4;
    static const COLS = 2;
    static const PER_PAGE = ROWS * COLS;

    function initialize(link) {
        View.initialize();
        _link = link;
    }

    function pageCount() {
        var sweep = _link.getRegistered().size();
        var rawPages = (sweep + PER_PAGE - 1) / PER_PAGE;
        return 1 + rawPages;
    }

    function nextPage() {
        _page = (_page + 1) % pageCount();
        WatchUi.requestUpdate();
    }

    function prevPage() {
        _page = (_page + pageCount() - 1) % pageCount();
        WatchUi.requestUpdate();
    }

    function onUpdate(dc) {
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Graphics.COLOR_TRANSPARENT, Theme.bg);
        dc.clear();

        if (_page == 0) {
            drawLinkPage(dc, w, h);
        } else {
            drawRawPage(dc, w, h, _page - 1);
        }

        // Page indicator, so it is obvious there is more than one screen.
        dc.setColor(Theme.textMuted, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.93, Graphics.FONT_XTINY,
            (_page + 1).format("%d") + "/" + pageCount().format("%d"),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // =====================================================================
    // Page 1 - link and handshake
    // =====================================================================

    //! These counters separate failure modes that look identical from the ride
    //! screen. "No telemetry" can mean the challenge never arrived, arrived
    //! corrupt, or was answered and rejected - and the fix differs for each.
    //!
    //!   rx bytes 0            nothing on the UART: wrong notify char, or the
    //!                         subscribe never landed
    //!   rx > 0, challenge 0   bytes arriving but no valid CRX frame
    //!   challenge > 0, sent 0 frame parsed, response could not be built
    //!   sent > 0, still shake response written and rejected - MD5_SPAN
    private function drawLinkPage(dc, w, h) {
        var state = _link.getBoardState();

        dc.setColor(Theme.accent, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.13, Graphics.FONT_XTINY,
            linkStateName() + "  " + fmt(state.rssi) + "dBm",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var rows = [
            [ "rx bytes",  _link.getRxTotal().format("%d") ],
            [ "challenge", _link.getChallengesSeen().format("%d") ],
            [ "bad frame", _link.getBadFrames().format("%d") ],
            [ "sent",      _link.getResponsesSent().format("%d") ],
            [ "tier",      _link.getTierIndex().format("%d")
                           + " (" + _link.getRegistered().size().format("%d") + ")"
                           + (_link.isProfileReady() ? " ok" : " ...") ],
            [ "reg try",   _link.getRegisterAttempts().format("%d") ],
            [ "fw",        fmt(state.peek(BoardState.FIRMWARE)) ]
        ];

        var top = h * 0.26;
        var rowH = (h * 0.58) / rows.size();

        for (var i = 0; i < rows.size(); i++) {
            var row = rows[i] as Lang.Array;
            var cy = top + (i * rowH);

            dc.setColor(Theme.textMuted, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 0.46, cy, Graphics.FONT_XTINY, row[0],
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

            dc.setColor(Theme.text, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 0.52, cy, Graphics.FONT_XTINY, row[1],
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // =====================================================================
    // Pages 2+ - raw sweep
    // =====================================================================

    private function drawRawPage(dc, w, h, rawPage) {
        var registered = _link.getRegistered() as Lang.Array;
        var state = _link.getBoardState();
        var start = rawPage * PER_PAGE;

        var top = h * 0.22;
        var rowH = (h * 0.62) / ROWS;

        for (var i = 0; i < PER_PAGE; i++) {
            var idx = start + i;
            if (idx >= registered.size()) { break; }

            var short = registered[idx] as Lang.String;
            var col = i % COLS;
            var row = i / COLS;
            var cx = (col == 0) ? (w * 0.29) : (w * 0.71);
            var cy = top + (row * rowH);

            dc.setColor(Theme.textMuted, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, cy, Graphics.FONT_XTINY,
                BoardUuids.shortLabel(short),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // The accent highlight is the identification mechanism: a value
            // that just moved is the one responding to whatever is being done
            // to the board.
            var changed = state.rawChangedRecently(short);
            dc.setColor(changed ? Theme.accent : Theme.text,
                        Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, cy + (rowH * 0.42), Graphics.FONT_XTINY,
                hex(state.getRaw(short)),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // =====================================================================

    //! Bytes as uppercase hex, no separators. Truncated past four bytes -
    //! anything longer will not fit a column and is not a telemetry scalar.
    private function hex(bytes as Lang.ByteArray?) as Lang.String {
        if (bytes == null) { return "--"; }
        var s = "";
        var n = bytes.size();
        if (n > 4) { n = 4; }
        for (var i = 0; i < n; i++) {
            s += bytes[i].format("%02X");
        }
        if (bytes.size() > 4) { s += ".."; }
        return s;
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
            case BoardLink.STATE_PROFILE_FAILED:  return "prof-fail";
            case BoardLink.STATE_UNLOCK_REJECTED: return "unlock-fail";
        }
        return "?";
    }
}

class DiagnosticsDelegate extends WatchUi.BehaviorDelegate {

    private var _view;

    function initialize(view) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onNextPage() {
        _view.nextPage();
        return true;
    }

    function onPreviousPage() {
        _view.prevPage();
        return true;
    }

    //! On button devices UP/DOWN arrive as previous/next page. Select is
    //! mapped too so a touch device can page without a swipe.
    function onSelect() {
        _view.nextPage();
        return true;
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
