using Toybox.WatchUi;
using Toybox.System;

//! Input for the ride screen.
//!
//! Button assignments follow the native activity apps deliberately: START
//! toggles recording, BACK backs out, MENU opens the menu. A rider glancing
//! down mid-ride should not have to remember that this app is different.
class RideDelegate extends WatchUi.BehaviorDelegate {

    private var _link;
    private var _recorder;

    function initialize(link, recorder) {
        BehaviorDelegate.initialize();
        _link = link;
        _recorder = recorder;
    }

    //! START: start recording, or pause an active recording.
    function onSelect() {
        if (_recorder.isRecording()) {
            _recorder.stop();
        } else {
            _recorder.start();
        }
        WatchUi.requestUpdate();
        return true;
    }

    //! BACK: leaving with an unsaved session would silently bin the ride, so
    //! an open session forces the save/discard decision first. With no
    //! session, fall through to the default and let the app exit.
    function onBack() {
        if (_recorder.hasSession()) {
            var menu = new WatchUi.Menu2({ :title => "End Ride" });
            menu.addItem(new WatchUi.MenuItem("Save",    null, :save,    {}));
            menu.addItem(new WatchUi.MenuItem("Discard", null, :discard, {}));
            menu.addItem(new WatchUi.MenuItem("Resume",  null, :resume,  {}));

            WatchUi.pushView(menu, new RideMenuDelegate(_link, _recorder),
                WatchUi.SLIDE_UP);
            return true;
        }
        return false;
    }

    function onMenu() {
        var menu = new WatchUi.Menu2({ :title => "carve" });
        menu.addItem(new WatchUi.MenuItem("Save Ride",    null, :save,       {}));
        menu.addItem(new WatchUi.MenuItem("Discard Ride", null, :discard,    {}));
        menu.addItem(new WatchUi.MenuItem("Reconnect",    null, :reconnect,  {}));
        menu.addItem(new WatchUi.MenuItem("Diagnostics",  null, :diagnostics,{}));

        WatchUi.pushView(menu, new RideMenuDelegate(_link, _recorder),
            WatchUi.SLIDE_UP);
        return true;
    }
}

class RideMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _link;
    private var _recorder;

    function initialize(link, recorder) {
        Menu2InputDelegate.initialize();
        _link = link;
        _recorder = recorder;
    }

    function onSelect(item) {
        var id = item.getId();

        if (id == :save) {
            _recorder.save();
            WatchUi.popView(WatchUi.SLIDE_DOWN);

        } else if (id == :discard) {
            _recorder.discard();
            WatchUi.popView(WatchUi.SLIDE_DOWN);

        } else if (id == :resume) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);

        } else if (id == :reconnect) {
            // Full teardown and rescan. The usual fix when the board has been
            // power-cycled underneath a live connection.
            _link.disconnect();
            _link.startScan();
            WatchUi.popView(WatchUi.SLIDE_DOWN);

        } else if (id == :diagnostics) {
            var view = new DiagnosticsView(_link);
            WatchUi.pushView(view, new DiagnosticsDelegate(view),
                WatchUi.SLIDE_LEFT);
        }
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
