//! Build identity.
//!
//! Shown on Diagnostics page 1. This exists because a sideloaded .prg is
//! consumed by the watch at install time and disappears from GARMIN/Apps,
//! so there is otherwise no way to tell which build is running - and during
//! protocol bring-up, "is this even the new code?" is a question that comes
//! up constantly and wastes a test cycle every time it is guessed wrong.
//!
//! Bump this with any change that gets flashed to hardware.
module Version {
    const BUILD = "0.7.0";
}
