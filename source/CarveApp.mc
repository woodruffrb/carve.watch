using Toybox.Application;
using Toybox.WatchUi;
using Toybox.Timer;
using Toybox.BluetoothLowEnergy as Ble;
using Toybox.System;

//! carve.watch - wrist telemetry for self-balancing single-wheel boards.
//!
//! The app owns the clock, not any View. Everything time-based hangs off one
//! 1 Hz tick here: the unlock keepalive, staleness detection, alert
//! evaluation, and the FIT record cadence.
//!
//! That placement is load-bearing. A View is destroyed when the user opens the
//! menu or the screen sleeps, and a keepalive that dies with it would let the
//! board freeze its telemetry 24 seconds into a menu dive. Owning the timer at
//! app scope is what makes the link survive the UI.
class CarveApp extends Application.AppBase {

    private var _link;
    private var _state;
    private var _alerts;
    private var _recorder;
    private var _tick;
    private var _view;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        Theme.init();

        _state    = new BoardState();
        _alerts   = new AlertEngine();
        _recorder = new RideRecorder();
        _link     = new BoardLink(_state);

        // Order matters: the delegate has to be installed before any GATT
        // work. Profile registration is asynchronous, so the scan really
        // starts from BoardLink.onProfileRegister - this call is the path for
        // the case where registration has somehow already completed.
        Ble.setDelegate(_link);
        _link.registerProfiles();
        _link.startScan();

        Fields.resetSession();

        _tick = new Timer.Timer();
        _tick.start(method(:onTick), 1000, true);
    }

    function onStop(state) {
        if (_tick != null) {
            _tick.stop();
            _tick = null;
        }

        // An in-progress ride is saved rather than dropped. Losing a ride
        // because the app was backed out of is not a defensible default.
        if (_recorder != null && _recorder.hasSession()) {
            _recorder.save();
        }
        if (_link != null) {
            _link.disconnect();
        }
    }

    //! Return type is explicit because Timer.start requires a
    //! `Method() as Void` and infers `as Any` without it.
    function onTick() as Void {
        _link.onTick();

        if (_state.isLive()) {
            Fields.accumulate(_state);
        }

        _recorder.onTick(_state);
        _alerts.evaluate(_state, _link.getState());

        WatchUi.requestUpdate();
    }

    function getInitialView() {
        _view = new RideView(_link, _alerts);
        return [ _view, new RideDelegate(_link, _recorder) ];
    }

    //! Settings arrive from Garmin Connect while the app is running, so every
    //! component that caches a threshold has to be told to re-read.
    function onSettingsChanged() {
        Theme.init();
        _state.reloadSettings();
        _alerts.reloadSettings();
        if (_view != null) {
            _view.reloadSettings();
        }
        WatchUi.requestUpdate();
    }
}
