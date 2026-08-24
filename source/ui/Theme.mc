using Toybox.Graphics;
using Toybox.System;

//! Colour tokens, carried over from the gerbdiff / Derivative.Engineering
//! palette so the watch app, the app UI and the website read as one family.
//!
//! Two palettes, picked at runtime rather than by resource qualifier:
//!
//!   MIP    - reflective, always-on, no burn-in risk. Wants maximum contrast
//!            and saturated accents; the muted greys that work on a desktop
//!            wash out completely in sunlight, so they are lifted.
//!   AMOLED - emissive, burn-in prone. Large filled areas are avoided and the
//!            always-on state drops to a dim, sparse variant.
//!
//! Detection uses DeviceSettings.requiresBurnInProtection, which is the
//! supported way to ask "is this an OLED panel" without a device allowlist.
module Theme {

    // ---- gerbdiff web tokens, verbatim ----------------------------------
    const WEB_BG          = 0x0a0a0a;
    const WEB_SURFACE     = 0x121212;
    const WEB_ELEVATED    = 0x1a1a1a;
    const WEB_TEXT        = 0xc9c9c9;
    const WEB_TEXT_BRIGHT = 0xf0f0f0;
    const WEB_TEXT_MUTED  = 0x7a7a7a;
    const WEB_ACCENT      = 0x007acc;
    const WEB_CYAN        = 0x4fc3f7;
    const WEB_SUCCESS     = 0x3fb950;
    const WEB_DANGER      = 0xf85149;
    const WEB_WARNING     = 0xffcc00;
    const WEB_BORDER      = 0x262626;

    // ---- resolved palette -----------------------------------------------
    var bg        = 0x000000;
    var surface   = WEB_ELEVATED;
    var border    = WEB_BORDER;
    var text      = WEB_TEXT_BRIGHT;
    var textMuted = WEB_TEXT_MUTED;
    var accent    = WEB_CYAN;
    var ok        = WEB_SUCCESS;
    var warn      = WEB_WARNING;
    var danger    = WEB_DANGER;

    var isAmoled  = false;
    var lowPower  = false;

    function init() {
        var settings = System.getDeviceSettings();
        isAmoled = (settings has :requiresBurnInProtection)
            && settings.requiresBurnInProtection;

        if (isAmoled) {
            // Emissive: the web tokens transfer almost unchanged, because the
            // panel renders them the way a monitor does.
            bg        = WEB_BG;
            surface   = WEB_SURFACE;
            border    = WEB_BORDER;
            text      = WEB_TEXT_BRIGHT;
            textMuted = WEB_TEXT_MUTED;
            accent    = WEB_CYAN;
        } else {
            // MIP: pure black costs nothing and buys contrast. Mid-greys are
            // lifted because a reflective panel in daylight crushes them, and
            // accents are pushed toward primaries to survive the 64-colour
            // quantisation on fenix-class displays.
            bg        = 0x000000;
            surface   = 0x1a1a1a;
            border    = 0x555555;
            text      = 0xffffff;
            textMuted = 0xaaaaaa;   // was 0x7a7a7a - invisible outdoors
            accent    = 0x55aaff;   // 0x4fc3f7 quantises muddy; this holds
        }
    }

    //! Foreground for a value that is fine, marginal, or in trouble.
    //! Centralised so every field agrees on what "marginal" looks like.
    function severityColor(severity) {
        if (severity >= Alerts.SEV_CRITICAL) { return danger; }
        if (severity >= Alerts.SEV_WARNING)  { return warn; }
        return text;
    }

    //! True when the UI should render sparse, dim and mostly-black: AMOLED
    //! always-on. On MIP this is always false, because there is nothing to
    //! protect and a dimmed screen is strictly worse to read.
    function shouldProtectDisplay() {
        return isAmoled && lowPower;
    }

    function dim(color) {
        // Halve each channel. Used only for the AMOLED always-on state.
        var r = (color >> 16) & 0xFF;
        var g = (color >> 8) & 0xFF;
        var b = color & 0xFF;
        return ((r / 2) << 16) | ((g / 2) << 8) | (b / 2);
    }
}
