using Toybox.ActivityRecording;
using Toybox.Activity;
using Toybox.FitContributor;
using Toybox.Application.Properties;

//! Records the ride as a FIT activity with board telemetry attached as
//! developer fields.
//!
//! This is the payoff for being a watch app rather than a data field. Board
//! battery, motor temperature and headroom ride along in the same FIT file as
//! GPS and heart rate, so a finished ride opens in Garmin Connect with the
//! board's own numbers graphed against the route - no export step, no second
//! app, and the data outlives the session.
//!
//! Field ids are part of the FIT file's contract with anything that parses it
//! later. They are stable; append, never renumber.
class RideRecorder {

    static const FIELD_BATTERY  = 0;
    static const FIELD_SPEED    = 1;
    static const FIELD_MOTOR_T  = 2;
    static const FIELD_HEADROOM = 3;
    static const FIELD_VOLTS    = 4;

    private var _session = null;
    private var _fBattery;
    private var _fSpeed;
    private var _fMotorT;
    private var _fHeadroom;
    private var _fVolts;

    private var _autoStart = true;
    private var _armed = false;

    //! Board speed in m/s above which auto-start fires. Low enough to catch a
    //! rolling start, high enough that shuffling the board around in a car
    //! park does not open a session.
    static const AUTO_START_MPS = 1.5;

    function initialize() {
        var v = Properties.getValue("autoStartRecording");
        _autoStart = (v == null) ? true : v;
    }

    function isRecording() {
        return _session != null && _session.isRecording();
    }

    function hasSession() {
        return _session != null;
    }

    function start() {
        if (_session == null) {
            _session = ActivityRecording.createSession({
                :name  => "Ride",
                :sport => Activity.SPORT_CYCLING
            });
            createFields();
            Fields.resetSession();
        }
        if (!_session.isRecording()) {
            _session.start();
        }
    }

    function stop() {
        if (_session != null && _session.isRecording()) {
            _session.stop();
        }
    }

    function save() {
        if (_session != null) {
            _session.stop();
            _session.save();
            _session = null;
        }
    }

    function discard() {
        if (_session != null) {
            _session.stop();
            _session.discard();
            _session = null;
        }
    }

    //! Sport is cycling rather than generic on purpose: Connect renders speed,
    //! distance and elevation for cycling, and shows a bare timer for generic.
    //! The activity is not cycling, but the presentation is the right one.
    private function createFields() {
        _fBattery = _session.createField("board_battery", FIELD_BATTERY,
            FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%" });

        _fSpeed = _session.createField("board_speed", FIELD_SPEED,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/s" });

        _fMotorT = _session.createField("motor_temp", FIELD_MOTOR_T,
            FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "C" });

        _fHeadroom = _session.createField("safety_headroom", FIELD_HEADROOM,
            FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%" });

        _fVolts = _session.createField("board_volts", FIELD_VOLTS,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "V" });
    }

    //! Called once per tick. Writes the current sample into the open session
    //! and handles auto-start.
    function onTick(state) {
        if (_autoStart && !isRecording() && !_armed) {
            var v = state.speedMps();
            if (v != null && v >= AUTO_START_MPS) {
                _armed = true;
                start();
            }
        }

        if (!isRecording()) { return; }

        // Only write fields we actually have. A developer field left unset for
        // a record is absent from the FIT file, which is correct - writing a
        // zero would fabricate a data point that never existed.
        var batt = state.get(BoardState.BATTERY_PCT);
        if (batt != null && _fBattery != null) { _fBattery.setData(batt); }

        var speed = state.speedMps();
        if (speed != null && _fSpeed != null) { _fSpeed.setData(speed); }

        var temp = state.get(BoardState.MOTOR_TEMP);
        if (temp != null && _fMotorT != null) { _fMotorT.setData(temp); }

        var head = state.get(BoardState.HEADROOM);
        if (head != null && _fHeadroom != null) { _fHeadroom.setData(head); }

        var volts = state.get(BoardState.BATTERY_V);
        if (volts != null && _fVolts != null) { _fVolts.setData(volts); }
    }
}
