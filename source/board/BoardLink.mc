using Toybox.BluetoothLowEnergy as Ble;
using Toybox.System;
using Toybox.Lang;

//! Owns the BLE link: scan, connect, unlock, keep alive, decode.
//!
//! Two properties of the Connect IQ BLE stack shape this whole class.
//!
//! First, only one GATT operation may be outstanding at a time. Issuing a
//! second read before the first completes silently drops it, which presents
//! as characteristics that never populate. Everything therefore goes through
//! _queue and is dispatched one at a time, advanced by completion callbacks.
//!
//! Second, the board stops refreshing telemetry unless it is re-challenged
//! within 24 seconds. The keepalive is not an optimisation - without it the
//! display freezes on stale numbers about half a minute into every ride.
class BoardLink extends Ble.BleDelegate {

    // ---- link states -----------------------------------------------------
    static const STATE_IDLE            = 0;
    static const STATE_SCANNING        = 1;
    static const STATE_CONNECTING      = 2;
    static const STATE_UNLOCKING       = 3;
    static const STATE_LIVE            = 4;
    static const STATE_PROFILE_FAILED  = 5;
    static const STATE_UNLOCK_REJECTED = 6;

    //! Re-challenge well inside the board's 24 s window. The margin absorbs a
    //! queue briefly backed up behind a slow read.
    static const KEEPALIVE_MS = 15000;

    //! After this many unanswered challenges the handshake is presumed wrong
    //! rather than unlucky - see Unlock.MD5_SPAN.
    static const UNLOCK_MAX_ATTEMPTS = 3;

    static const MAX_QUEUE_DEPTH = 8;

    private var _state = STATE_IDLE;
    private var _device = null;
    private var _profileReady = false;

    private var _queue as Lang.Array = [];
    private var _busy = false;

    private var _rxBuffer as Lang.ByteArray = []b;
    private var _lastUnlockMs = 0;
    private var _unlockAttempts = 0;

    private var _boardState;
    private var _pollCursor = 0;
    private var _pollList as Lang.Array;

    function initialize(boardState) {
        BleDelegate.initialize();
        _boardState = boardState;

        // Polled round-robin, one per tick. Everything else arrives by
        // subscription.
        _pollList = [
            BoardUuids.TRIP_ODOMETER,
            BoardUuids.TEMPERATURE,
            BoardUuids.BATTERY_VOLTS,
            BoardUuids.SAFETY_HEADROOM
        ];
    }

    function getState()      { return _state; }
    function getBoardState() { return _boardState; }

    // =====================================================================
    // Lifecycle
    // =====================================================================

    //! Register the GATT profile. Must happen exactly once per app lifetime,
    //! before any connection, and must complete before scanning is useful.
    function registerProfiles() {
        var chars = [];
        var shortForms = BoardUuids.registeredCharacteristics();
        var notify = BoardUuids.notifyCharacteristics();

        for (var i = 0; i < shortForms.size(); i++) {
            var short = shortForms[i] as Lang.String;
            var entry = { :uuid => BoardUuids.uuid(short) };

            // Only characteristics we actually subscribe to get a CCCD
            // registered. Descriptors are not free and the registration
            // budget is the binding constraint here.
            if (needsCccd(short, notify)) {
                entry[:descriptors] = [ Ble.cccdUuid() ];
            }
            chars.add(entry);
        }

        try {
            Ble.registerProfile({
                :uuid => BoardUuids.serviceUuid(),
                :characteristics => chars
            });
        } catch (ex) {
            // Thrown when the registration budget is exceeded. Surfacing this
            // as a state rather than swallowing it is what makes an over-long
            // characteristic list debuggable instead of mysterious.
            _state = STATE_PROFILE_FAILED;
        }
    }

    private function needsCccd(short as Lang.String, notifyList as Lang.Array) as Lang.Boolean {
        if (short.equals(BoardUuids.UART_READ)) { return true; }
        for (var i = 0; i < notifyList.size(); i++) {
            if (short.equals(notifyList[i])) { return true; }
        }
        return false;
    }

    //! Scanning before onProfileRegister has confirmed is wasted work: a
    //! connection made without a registered profile exposes no characteristics
    //! at all. The app calls this once at startup and again on disconnect, so
    //! a not-yet-ready profile simply defers to the next call.
    function startScan() {
        if (_state == STATE_PROFILE_FAILED || !_profileReady) { return; }
        _state = STATE_SCANNING;
        Ble.setScanState(Ble.SCAN_STATE_SCANNING);
    }

    function stopScan() {
        Ble.setScanState(Ble.SCAN_STATE_OFF);
    }

    function disconnect() {
        if (_device != null) {
            Ble.unpairDevice(_device);
            _device = null;
        }
        _queue = [];
        _busy = false;
        _boardState.connected = false;
        _boardState.unlocked = false;
        _boardState.clearTelemetry();
        _state = STATE_IDLE;
    }

    // =====================================================================
    // Tick - driven at 1 Hz by the app
    // =====================================================================

    function onTick() {
        if (_state != STATE_LIVE && _state != STATE_UNLOCKING) {
            return;
        }

        var now = System.getTimer();
        if (now - _lastUnlockMs >= KEEPALIVE_MS) {
            if (_state == STATE_UNLOCKING
                && _unlockAttempts >= UNLOCK_MAX_ATTEMPTS) {
                // Three challenges answered with no telemetry back. The
                // response is being rejected, not lost.
                _state = STATE_UNLOCK_REJECTED;
                return;
            }
            requestChallenge();
        }

        if (_state == STATE_LIVE) {
            pollNext();
        }
        pump();
    }

    //! One polled characteristic per tick, round robin. Reading all four every
    //! second outpaces what the queue drains and starves the handshake.
    private function pollNext() {
        if (_pollList.size() == 0) { return; }
        var short = _pollList[_pollCursor % _pollList.size()] as Lang.String;
        _pollCursor++;
        enqueue({ :kind => :read, :char => short });
    }

    // =====================================================================
    // GATT operation queue
    // =====================================================================

    private function enqueue(op as Lang.Dictionary) as Void {
        // Bound the queue. If it is backing up the link is unhealthy, and
        // piling on more reads makes recovery slower rather than faster.
        if (_queue.size() >= MAX_QUEUE_DEPTH) { return; }
        _queue.add(op);
        pump();
    }

    private function pump() {
        if (_busy || _queue.size() == 0 || _device == null) { return; }

        var svc = _device.getService(BoardUuids.serviceUuid());
        if (svc == null) { _queue = []; return; }

        var op = _queue[0] as Lang.Dictionary;
        var ch = svc.getCharacteristic(BoardUuids.uuid(op[:char]));
        if (ch == null) {
            // Not registered, or this board does not expose it. Drop it and
            // move on rather than wedging the queue.
            dropHead();
            pump();
            return;
        }

        _busy = true;
        try {
            if (op[:kind] == :read) {
                ch.requestRead();
            } else if (op[:kind] == :write) {
                ch.requestWrite(op[:value], { :writeType => Ble.WRITE_TYPE_DEFAULT });
            } else if (op[:kind] == :subscribe) {
                var cccd = ch.getDescriptor(Ble.cccdUuid());
                if (cccd == null) {
                    _busy = false;
                    dropHead();
                    pump();
                    return;
                }
                cccd.requestWrite([0x01, 0x00]b);
            }
        } catch (ex) {
            _busy = false;
            dropHead();
        }
    }

    private function dropHead() {
        if (_queue.size() > 0) {
            _queue = _queue.slice(1, null);
        }
    }

    private function complete() {
        _busy = false;
        dropHead();
        pump();
    }

    // =====================================================================
    // Handshake
    // =====================================================================

    //! Ask the board for a fresh challenge by echoing its firmware revision
    //! back at it. This is the documented trigger; nothing else provokes one.
    private function requestChallenge() {
        var fw = _boardState.peek(BoardState.FIRMWARE);
        if (fw == null) {
            enqueue({ :kind => :read, :char => BoardUuids.FIRMWARE_REV });
            return;
        }
        _rxBuffer = []b;
        _lastUnlockMs = System.getTimer();
        enqueue({
            :kind  => :write,
            :char  => BoardUuids.FIRMWARE_REV,
            :value => encodeUint16(fw)
        });
    }

    //! Accumulate UART notifications until a full 20-byte frame has arrived.
    //! The board splits the challenge across packets, so a single
    //! onCharacteristicChanged is not a frame.
    private function onUartBytes(value as Lang.ByteArray) as Void {
        _rxBuffer = _rxBuffer.addAll(value);

        if (_rxBuffer.size() < Unlock.FRAME_LEN) { return; }

        var frame = _rxBuffer.slice(0, Unlock.FRAME_LEN);
        _rxBuffer = []b;

        if (!Unlock.frameIsIntact(frame)) {
            // Reassembly went wrong, or this was not a challenge. Let the
            // keepalive timer retry rather than hammering the board.
            return;
        }

        var response = Unlock.buildResponse(frame);
        if (response == null) { return; }

        _unlockAttempts++;
        enqueue({
            :kind  => :write,
            :char  => BoardUuids.UART_WRITE,
            :value => response
        });
    }

    // =====================================================================
    // BleDelegate callbacks
    // =====================================================================

    //! Registration is asynchronous, so this - not app startup - is where
    //! scanning actually begins. The startScan() call in onStart runs before
    //! this fires and deliberately no-ops.
    function onProfileRegister(uuid, status) {
        if (status == Ble.STATUS_SUCCESS) {
            _profileReady = true;
            startScan();
        } else {
            _state = STATE_PROFILE_FAILED;
        }
    }

    //! Iterators here yield Object, so each element needs an explicit cast
    //! before its ScanResult / Uuid members are reachable.
    //!
    //! Matching accepts either the advertised service UUID or the device name
    //! prefix. Service UUID is the better identifier and is tried first, but
    //! getServiceUuids() reads the *advertisement*, not the GATT table - a
    //! peripheral is free to expose a service it never advertises. Boards name
    //! themselves "OW" followed by digits, which is a serviceable fallback.
    function onScanResults(scanResults) {
        if (_state != STATE_SCANNING) { return; }

        for (var item = scanResults.next(); item != null; item = scanResults.next()) {
            var result = item as Ble.ScanResult;

            if (advertisesService(result) || nameLooksLikeBoard(result)) {
                _boardState.rssi = result.getRssi();
                stopScan();
                _state = STATE_CONNECTING;
                _device = Ble.pairDevice(result);
                return;
            }
        }
    }

    private function advertisesService(result as Ble.ScanResult) as Lang.Boolean {
        // getServiceUuids always returns an iterator, never null - a guard
        // here is dead code, and the compiler says so.
        var uuids = result.getServiceUuids();
        for (var u = uuids.next(); u != null; u = uuids.next()) {
            var uuid = u as Ble.Uuid;
            if (uuid.equals(BoardUuids.serviceUuid())) {
                return true;
            }
        }
        return false;
    }

    private function nameLooksLikeBoard(result as Ble.ScanResult) as Lang.Boolean {
        var name = result.getDeviceName();
        if (name == null || name.length() < 2) { return false; }
        return name.substring(0, 2).toLower().equals("ow");
    }

    function onConnectedStateChanged(device, state) {
        if (state == Ble.CONNECTION_STATE_CONNECTED) {
            _device = device;
            _boardState.connected = true;
            _state = STATE_UNLOCKING;
            _unlockAttempts = 0;
            _lastUnlockMs = System.getTimer();
            _queue = [];
            _busy = false;

            // Documented order: read the firmware revision, subscribe to the
            // UART characteristic, then echo the revision back to provoke a
            // challenge. The subscribe has to land before the echo or the
            // challenge arrives with nobody listening.
            enqueue({ :kind => :read,      :char => BoardUuids.FIRMWARE_REV });
            enqueue({ :kind => :subscribe, :char => BoardUuids.UART_READ });

            var notify = BoardUuids.notifyCharacteristics();
            for (var i = 0; i < notify.size(); i++) {
                enqueue({ :kind => :subscribe, :char => notify[i] });
            }
        } else {
            _boardState.connected = false;
            _boardState.unlocked = false;
            _boardState.clearTelemetry();
            _device = null;
            _queue = [];
            _busy = false;
            startScan();
        }
    }

    function onCharacteristicRead(characteristic, status, value) {
        if (status == Ble.STATUS_SUCCESS) {
            decode(characteristic.getUuid(), value);
        }
        complete();
    }

    function onCharacteristicWrite(characteristic, status) {
        complete();
    }

    function onDescriptorWrite(descriptor, status) {
        complete();

        // Once the subscription queue has drained, provoke the challenge.
        if (_state == STATE_UNLOCKING && _queue.size() == 0) {
            requestChallenge();
        }
    }

    function onCharacteristicChanged(characteristic, value) {
        var uuid = characteristic.getUuid();

        if (uuid.equals(BoardUuids.uuid(BoardUuids.UART_READ))) {
            onUartBytes(value);
            return;
        }
        decode(uuid, value);

        // Telemetry arriving on a subscription is the only proof the unlock
        // actually took. The board acknowledges a bad response exactly the way
        // it acknowledges a good one, so the write status tells us nothing.
        if (_state == STATE_UNLOCKING) {
            _boardState.unlocked = true;
            _state = STATE_LIVE;
            _unlockAttempts = 0;
        }
    }

    // =====================================================================
    // Decoding - all multi-byte values are big-endian
    // =====================================================================

    private function decode(uuid as Ble.Uuid, value as Lang.ByteArray?) as Void {
        if (value == null || value.size() == 0) { return; }

        if (uuid.equals(BoardUuids.uuid(BoardUuids.BATTERY_PCT))) {
            _boardState.put(BoardState.BATTERY_PCT, value[0]);

        } else if (uuid.equals(BoardUuids.uuid(BoardUuids.RPM))) {
            _boardState.put(BoardState.RPM, u16(value));

        } else if (uuid.equals(BoardUuids.uuid(BoardUuids.TRIP_ODOMETER))) {
            // Reported in tenths of a mile.
            _boardState.put(BoardState.TRIP_M, u16(value) * 160.9344);

        } else if (uuid.equals(BoardUuids.uuid(BoardUuids.TEMPERATURE))) {
            // High byte is the controller, low byte the motor.
            _boardState.put(BoardState.MOTOR_TEMP, value[value.size() - 1]);

        } else if (uuid.equals(BoardUuids.uuid(BoardUuids.BATTERY_VOLTS))) {
            _boardState.put(BoardState.BATTERY_V, u16(value) / 10.0);

        } else if (uuid.equals(BoardUuids.uuid(BoardUuids.SAFETY_HEADROOM))) {
            _boardState.put(BoardState.HEADROOM, value[0]);

        } else if (uuid.equals(BoardUuids.uuid(BoardUuids.STATUS_ERROR))) {
            _boardState.put(BoardState.STATUS_FLAGS, u16(value));

        } else if (uuid.equals(BoardUuids.uuid(BoardUuids.FIRMWARE_REV))) {
            _boardState.put(BoardState.FIRMWARE, u16(value));
        }
    }

    private function u16(value as Lang.ByteArray) as Lang.Number {
        if (value.size() < 2) { return value[0]; }
        return value.decodeNumber(Lang.NUMBER_FORMAT_UINT16, {
            :offset => 0,
            :endianness => Lang.ENDIAN_BIG
        });
    }

    private function encodeUint16(n as Lang.Number) as Lang.ByteArray {
        return [ (n >> 8) & 0xFF, n & 0xFF ]b;
    }
}
