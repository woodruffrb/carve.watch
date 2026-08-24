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

    //! How many full passes through the variant search to make before
    //! declaring the handshake rejected.
    //!
    //! This replaces a flat three-attempt cap that predated the search and
    //! silently defeated it: the cap tripped on the third response, before
    //! even the original four variants had been tried, so the run ended in
    //! UNLOCK FAILED while still reporting "span 2 try". A give-up threshold
    //! has to outlast the search it is supervising.
    static const UNLOCK_MIN_ROUNDS = 3;

    //! Challenge interval while the variant search is still running.
    //!
    //! The 15 s keepalive exists to stay inside the board's 24 s window during
    //! a ride; using it to pace a search made sixteen attempts take four
    //! minutes of standing next to the board. While searching, each challenge
    //! is just a characteristic write, so ask far more often and let the
    //! normal keepalive take over once the link is live.
    static const SEARCH_CHALLENGE_MS = 2500;

    //! How long to wait for a first challenge before concluding the board
    //! does not use the handshake at all.
    //!
    //! The challenge-response was introduced in later firmware. Older boards -
    //! the reference board reads firmware 0x1045, i.e. 4165 - never send a
    //! challenge, so an app that treats the unlock as mandatory waits forever
    //! for a frame that is not coming, while the telemetry characteristics sit
    //! there perfectly readable. Treat the handshake as conditional: if no
    //! challenge arrives in this window, go live and poll.
    //!
    //! The keepalive keeps running regardless, so a board that does want the
    //! handshake still gets one; this only stops the absence of a challenge
    //! from being fatal.
    static const UNLOCK_GRACE_MS = 10000;

    static const MAX_QUEUE_DEPTH = 8;

    //! Reads issued per tick. Enough to cycle the full 32-characteristic
    //! sweep in a few seconds so a value visibly reacts to spinning the
    //! wheel; the queue bound stops it running away.
    static const POLLS_PER_TICK = 6;

    //! How long to wait for onProfileRegister before assuming the request was
    //! dropped.
    //!
    //! An over-wide registration does not always fail loudly. On hardware it
    //! can neither throw nor call back at all, which left the app parked in
    //! STATE_IDLE forever waiting on a callback that was never coming - it
    //! showed as a permanent "OFFLINE" with no indication why. Silence is
    //! therefore treated as failure, and falls back to a narrower tier.
    static const REGISTER_TIMEOUT_MS = 4000;

    //! Connect IQ allows at most 3 registered profiles per app lifetime, and
    //! every attempt spends one whether or not it succeeds.
    //!
    //! This is why the original wide-to-narrow ladder could not work: six
    //! attempts burned the budget, so the last three failed on the profile cap
    //! rather than on their width, and the app reported a width problem that
    //! was really an attempt-count problem. Keep the ladder shorter than the
    //! cap and start at a width that is expected to succeed.
    static const MAX_REGISTER_ATTEMPTS = 3;

    //! The rung at which descriptors are dropped from the registration.
    //!
    //! Both descriptor-carrying attempts were accepted and then silently
    //! ignored - no throw, no callback - which is not a width failure and not
    //! a budget failure. A malformed or unwanted descriptor list is the
    //! remaining thing in the profile that could sink it wholesale, so the
    //! last rung registers the same characteristics with no CCCDs at all.
    //!
    //! If this rung is the one that registers, descriptors are the fault.
    //! The cost is that nothing can be subscribed, so everything is polled.
    static const TIER_WITHOUT_DESCRIPTORS = 99;

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
    private var _pollList as Lang.Array = [];

    private var _tierIndex = 0;
    private var _registered as Lang.Array = [];
    private var _registerPendingSince = 0;
    private var _registerAttempts = 0;
    private var _lastError as Lang.String = "";
    private var _useDescriptors = true;

    // Scan-path instrumentation, separate from registration.
    //
    // onScanStateChange was never implemented, so there has been no evidence
    // about whether the scan subsystem responds at all - only about
    // registration. These are different code paths and may fail differently.
    private var _scanCallbacks = 0;
    private var _lastScanStatus = -1;
    private var _lastScanState = -1;
    private var _scanResultCount = 0;
    private var _connectedAtMs = 0;
    private var _handshakeSkipped = false;

    //! The most recent 20-byte frame and the checksum comparison for it.
    //!
    //! Ten frames arrived and all ten were rejected, which is either a wrong
    //! signature or a wrong checksum rule - indistinguishable without the
    //! bytes. Guessing between them has already cost enough; keep the frame.
    private var _lastFrame as Lang.ByteArray = []b;
    private var _lastCalcSum = -1;
    private var _lastRecvSum = -1;

    //! The response actually written to the board.
    //!
    //! The algorithm has been verified off-device against a captured
    //! challenge, so the open question is whether this Monkey C produces the
    //! same bytes. Without showing them that is unanswerable, and it has
    //! already been guessed at once too often.
    private var _lastResponse as Lang.ByteArray = []b;

    private var _spanAttempt = 0;
    private var _spanVariant = 0;
    private var _spanSolved = -1;

    //! True when the link went live without a verified handshake. The data on
    //! screen may be stale, so this is surfaced rather than hidden.
    private var _unlockUnverified = false;

    // Registration outcome instrumentation.
    //
    // The earlier "timeout" label was set in the tiers-exhausted branch, not
    // where a timeout actually happened, so it reported the same string
    // whether onProfileRegister returned a failure status or was never called
    // at all. Those are different faults with different fixes, and conflating
    // them is why several builds failed to narrow anything. Count the
    // callbacks and keep the status code.
    private var _profileCallbacks = 0;
    private var _lastStatus = -1;
    private var _timeouts = 0;

    // ---- handshake instrumentation --------------------------------------
    // Read by DiagnosticsView. Without these a stalled handshake is opaque:
    // "no telemetry" looks identical whether the challenge never arrived, or
    // arrived malformed, or was answered and rejected.
    private var _rxTotal = 0;          // UART bytes received since connect
    private var _challengesSeen = 0;   // well-formed CRX frames
    private var _badFrames = 0;        // frames that failed the checksum
    private var _responsesSent = 0;

    function initialize(boardState) {
        BleDelegate.initialize();
        _boardState = boardState;
    }

    function getRxTotal()        as Lang.Number { return _rxTotal; }
    function getChallengesSeen() as Lang.Number { return _challengesSeen; }
    function getBadFrames()      as Lang.Number { return _badFrames; }
    function getResponsesSent()  as Lang.Number { return _responsesSent; }
    function getUnlockAttempts() as Lang.Number { return _unlockAttempts; }

    function getState()      { return _state; }
    function getBoardState() { return _boardState; }

    // =====================================================================
    // Lifecycle
    // =====================================================================

    //! Register the GATT profile, widest tier that the device accepts.
    //!
    //! Connect IQ's registration limit is undocumented, so instead of picking
    //! a number and hoping, this walks BoardUuids.tier() from widest to
    //! narrowest until one sticks. Failure arrives by two different routes -
    //! a synchronous throw, or a non-success status in onProfileRegister - so
    //! both funnel back into the same fallback.
    //!
    //! The widest tier that registers is what Diagnostics can show, which is
    //! why this tries hard rather than settling for the minimum.
    function registerProfiles() {
        tryRegisterTier(0);
    }

    private function tryRegisterTier(index as Lang.Number) as Void {
        if (_registerAttempts >= MAX_REGISTER_ATTEMPTS) {
            // Out of profile budget. Trying again cannot succeed and would
            // only replace a real error message with a cap error.
            if (_lastError.equals("")) { _lastError = "budget"; }
            _state = STATE_PROFILE_FAILED;
            return;
        }

        var shortForms = BoardUuids.tier(index);
        if (shortForms == null) {
            // Even the minimum was refused. Nothing further to try.
            // Say which way it actually failed rather than assuming.
            if (_lastError.equals("")) {
                _lastError = (_profileCallbacks > 0)
                    ? ("status " + _lastStatus.format("%d"))
                    : "no callback";
            }
            _state = STATE_PROFILE_FAILED;
            return;
        }

        _tierIndex = index;
        _registered = shortForms;
        _useDescriptors = (index < TIER_WITHOUT_DESCRIPTORS);
        _registerAttempts++;
        _registerPendingSince = System.getTimer();

        var chars = [];
        var notify = BoardUuids.notifyCharacteristics();

        for (var i = 0; i < shortForms.size(); i++) {
            var short = shortForms[i] as Lang.String;
            var entry = { :uuid => BoardUuids.uuid(short) };

            // Only characteristics we subscribe to get a CCCD, and only while
            // descriptors are still in play at all.
            if (_useDescriptors && needsCccd(short, notify)) {
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
            // Keep the message. Discarding it is what turned a diagnosable
            // failure into three rounds of guessing - the exception says
            // whether this is a permission problem, a profile-budget problem
            // or something else entirely.
            var msg = ex.getErrorMessage();
            _lastError = (msg == null) ? "throw" : msg;
            tryRegisterTier(index + 1);
        }
    }

    //! A registration that neither threw nor called back is a dropped
    //! registration. Give it up as failed and try something narrower.
    private function checkRegistrationTimeout() as Void {
        if (_profileReady) { return; }
        if (_state == STATE_PROFILE_FAILED) { return; }
        if (_registerPendingSince == 0) { return; }

        if (System.getTimer() - _registerPendingSince < REGISTER_TIMEOUT_MS) {
            return;
        }
        _timeouts++;
        tryRegisterTier(_tierIndex + 1);
    }

    //! Which characteristics actually registered, and at which tier. Shown in
    //! Diagnostics so a narrow sweep is visible rather than looking like
    //! missing data.
    function getRegistered() as Lang.Array { return _registered; }
    function getTierIndex() as Lang.Number { return _tierIndex; }
    function getRegisterAttempts() as Lang.Number { return _registerAttempts; }
    function isProfileReady() as Lang.Boolean { return _profileReady; }
    function getLastError() as Lang.String { return _lastError; }
    function usesDescriptors() as Lang.Boolean { return _useDescriptors; }
    function getProfileCallbacks() as Lang.Number { return _profileCallbacks; }
    function getLastStatus() as Lang.Number { return _lastStatus; }
    function getTimeouts() as Lang.Number { return _timeouts; }
    function getScanCallbacks() as Lang.Number { return _scanCallbacks; }
    function getLastScanStatus() as Lang.Number { return _lastScanStatus; }
    function getLastScanState() as Lang.Number { return _lastScanState; }
    function getScanResultCount() as Lang.Number { return _scanResultCount; }
    function isHandshakeSkipped() as Lang.Boolean { return _handshakeSkipped; }
    function getLastFrame() as Lang.ByteArray { return _lastFrame; }
    function getLastResponse() as Lang.ByteArray { return _lastResponse; }
    function getLastCalcSum() as Lang.Number { return _lastCalcSum; }
    function getLastRecvSum() as Lang.Number { return _lastRecvSum; }
    function getSpanVariant() as Lang.Number { return _spanVariant; }
    function getSpanAttempt() as Lang.Number { return _spanAttempt; }
    function isUnlockUnverified() as Lang.Boolean { return _unlockUnverified; }
    function getSpanSolved() as Lang.Number { return _spanSolved; }

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
    //! Scanning deliberately does NOT wait for profile registration.
    //!
    //! The profile governs GATT operations once connected; discovery does not
    //! need it. Gating the scan on _profileReady meant that when registration
    //! silently failed, the app never even attempted to scan - so a
    //! registration fault and a scan fault were indistinguishable, and the
    //! scan path went completely untested.
    function startScan() {
        _state = STATE_SCANNING;
        try {
            Ble.setScanState(Ble.SCAN_STATE_SCANNING);
        } catch (ex) {
            var m = ex.getErrorMessage();
            _lastError = (m == null) ? "scan throw" : m;
            _state = STATE_PROFILE_FAILED;
        }
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
        // Checked before the state guard on purpose: registration happens
        // while the link is still IDLE, so a guard-first tick would never
        // notice a dropped registration.
        checkRegistrationTimeout();

        if (_state != STATE_LIVE && _state != STATE_UNLOCKING) {
            return;
        }

        var now = System.getTimer();

        // Only skip when *nothing at all* has arrived on the UART. Frames
        // arriving but failing to parse is a decoding bug, not an absent
        // handshake, and skipping in that case would paper over it.
        if (_state == STATE_UNLOCKING
            && _rxTotal == 0
            && (now - _connectedAtMs) >= UNLOCK_GRACE_MS) {
            _state = STATE_LIVE;
            _boardState.unlocked = true;
            _handshakeSkipped = true;
        }

        // Search fast, then settle into the ride-time keepalive.
        var interval = (_state == STATE_UNLOCKING && _spanSolved < 0)
            ? SEARCH_CHALLENGE_MS
            : KEEPALIVE_MS;

        if (now - _lastUnlockMs >= interval) {
            if (_state == STATE_UNLOCKING
                && _spanAttempt >= (Unlock.VARIANT_COUNT * UNLOCK_MIN_ROUNDS)) {
                // Every span and hash order tried twice, all rejected. Rather
                // than stop here, go live and poll anyway.
                //
                // The premise that an unlock is required has never actually
                // been tested on this board. The challenge frames carry no CRX
                // signature, so they may not be challenges at all - and if
                // this firmware does not gate reads behind a handshake, the
                // characteristics are readable right now and the whole search
                // was solving a problem that does not exist.
                //
                // Polling settles it in seconds: real-looking values mean no
                // unlock is needed; zeros or stale values mean it is.
                _state = STATE_LIVE;
                _unlockUnverified = true;
                buildPollList();
            }
            requestChallenge();
        }

        if (_state == STATE_LIVE) {
            pollNext();
        }
        pump();
    }

    //! Round-robin poll across everything registered.
    //!
    //! Reads several per tick rather than one. On the wide sweep tier a
    //! one-per-second cursor takes half a minute to get round the range,
    //! which is far too slow to watch a value react to spinning the wheel.
    //! The queue bound is what actually limits the rate.
    private function pollNext() {
        if (_pollList.size() == 0) { return; }

        for (var n = 0; n < POLLS_PER_TICK; n++) {
            var short = _pollList[_pollCursor % _pollList.size()] as Lang.String;
            _pollCursor++;
            enqueue({ :kind => :read, :char => short });
        }
    }

    //! Everything registered except the UART pair, which is not polled -
    //! the read side is notify-only and the write side is write-only.
    private function buildPollList() as Void {
        _pollList = [];
        for (var i = 0; i < _registered.size(); i++) {
            var short = _registered[i] as Lang.String;
            if (short.equals(BoardUuids.UART_READ)) { continue; }
            if (short.equals(BoardUuids.UART_WRITE)) { continue; }
            _pollList.add(short);
        }
        _pollCursor = 0;
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

    //! Handshake traffic jumps the queue and ignores the depth bound.
    //!
    //! This is not an optimisation. Polling can fill the queue, and if a
    //! keepalive write got dropped for being one op too many, the board would
    //! freeze its telemetry 24 seconds later - an intermittent failure that
    //! would look like a flaky radio and be miserable to diagnose. The
    //! handshake must never lose to a poll.
    private function enqueuePriority(op as Lang.Dictionary) as Void {
        var next = [ op ];
        for (var i = 0; i < _queue.size(); i++) {
            next.add(_queue[i]);
        }
        _queue = next;
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
            enqueuePriority({ :kind => :read, :char => BoardUuids.FIRMWARE_REV });
            return;
        }
        _rxBuffer = []b;
        _lastUnlockMs = System.getTimer();
        enqueuePriority({
            :kind  => :write,
            :char  => BoardUuids.FIRMWARE_REV,
            :value => encodeUint16(fw)
        });
    }

    //! Accumulate UART notifications until a full 20-byte frame has arrived.
    //! The board splits the challenge across packets, so a single
    //! onCharacteristicChanged is not a frame.
    private function onUartBytes(value as Lang.ByteArray) as Void {
        _rxTotal += value.size();
        _rxBuffer = _rxBuffer.addAll(value);

        if (_rxBuffer.size() < Unlock.FRAME_LEN) { return; }

        var frame = _rxBuffer.slice(0, Unlock.FRAME_LEN);
        _rxBuffer = []b;

        // Record the FIRST frame and hold it.
        //
        // During the search a fresh challenge arrives every 2.5 s, so a
        // rolling capture means the frame page and the response page describe
        // different exchanges by the time both have been read - which made the
        // two screenshots impossible to compare. Freezing the first pair keeps
        // them consistent for as long as it takes to page across.
        if (_lastFrame.size() == 0) {
            _lastFrame = frame;
            _lastCalcSum = Unlock.xorChecksum(frame.slice(0, Unlock.FRAME_LEN - 1));
            _lastRecvSum = frame[Unlock.FRAME_LEN - 1];
        }

        if (!Unlock.frameIsIntact(frame)) {
            // Reassembly went wrong, or this was not a challenge. Let the
            // keepalive timer retry rather than hammering the board.
            _badFrames++;
            return;
        }
        _challengesSeen++;

        // Cycle the MD5 span on each challenge. Which bytes feed the hash is
        // the one genuinely unknown part of the handshake, and challenges
        // arrive repeatedly - so try a different candidate each time rather
        // than spending a rebuild-and-reflash cycle per guess. Whichever
        // variant is in flight when telemetry starts is the correct one, and
        // it is latched in onCharacteristicChanged.
        if (_spanSolved >= 0) {
            _spanVariant = _spanSolved;
        } else {
            _spanVariant = _spanAttempt % Unlock.VARIANT_COUNT;
            _spanAttempt++;
        }

        var response = Unlock.buildResponse(frame, _spanVariant);
        if (response == null) { return; }

        // Frozen alongside the frame it answers, for the same reason.
        if (_lastResponse.size() == 0) {
            _lastResponse = response;
        }

        _unlockAttempts++;
        _responsesSent++;
        enqueuePriority({
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
    //!
    //! A non-success status is the other way an over-wide tier fails, so it
    //! falls back rather than giving up. tryRegisterTier gives up on its own
    //! once the tiers are exhausted.
    //! Reports whether the scan subsystem accepted the state change. If this
    //! fires while onProfileRegister never does, BLE callbacks work and the
    //! fault is confined to registration.
    function onScanStateChange(scanState, status) {
        _scanCallbacks++;
        _lastScanState = (scanState == null) ? -2 : scanState;
        _lastScanStatus = (status == null) ? -2 : status;
    }

    function onProfileRegister(uuid, status) {
        _profileCallbacks++;
        _lastStatus = (status == null) ? -2 : status;

        if (status == Ble.STATUS_SUCCESS) {
            _profileReady = true;
            startScan();
        } else {
            tryRegisterTier(_tierIndex + 1);
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

        for (var item = scanResults.next(); item != null; item = scanResults.next()) {
            var result = item as Ble.ScanResult;
            _scanResultCount++;

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
            _connectedAtMs = System.getTimer();
            _handshakeSkipped = false;
            _unlockUnverified = false;
            _spanAttempt = 0;
            _lastFrame = []b;
            _lastResponse = []b;
            _queue = [];
            _busy = false;

            // Counters are per-connection; carrying them across a reconnect
            // would make Diagnostics misleading about the current attempt.
            _rxTotal = 0;
            _challengesSeen = 0;
            _badFrames = 0;
            _responsesSent = 0;

            buildPollList();

            // Documented order: read the firmware revision, subscribe to the
            // UART characteristic, then echo the revision back to provoke a
            // challenge. The subscribe has to land before the echo or the
            // challenge arrives with nobody listening.
            enqueue({ :kind => :read,      :char => BoardUuids.FIRMWARE_REV });
            enqueue({ :kind => :subscribe, :char => BoardUuids.UART_READ });

            // No descriptors registered means no CCCD to write, so there is
            // nothing to subscribe to and every value has to be polled. The
            // poll list already covers them.
            if (_useDescriptors) {
                var notify = BoardUuids.notifyCharacteristics();
                for (var i = 0; i < notify.size(); i++) {
                    enqueue({ :kind => :subscribe, :char => notify[i] });
                }
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

    //! A successfully written unlock response is the proof the handshake
    //! completed - not a notification.
    //!
    //! Success was previously detected only by a telemetry notification
    //! arriving. That is the wrong evidence: reads work and the UART
    //! subscription works, but the board does not necessarily push the
    //! telemetry characteristics, so a perfectly good unlock produced no
    //! notification, was read as failure, and the app re-challenged forever
    //! while sending provably correct responses.
    //!
    //! Verified byte-for-byte against the reference implementation:
    //!   challenge 09 8E 56 6D 05 3B 63 6D C9 A7 20 04 55 29 80 19 80 5A A7 5E
    //!   response  09 8E 56 36 BD BD 95 D7 F1 14 61 F7 C7 4E C3 FC 13 4B CF F7
    //!
    //! So going live here and polling is correct. If the unlock had in fact
    //! failed, the polled values would be stale and isLive() would say so.
    function onCharacteristicWrite(characteristic, status) {
        if (_state == STATE_UNLOCKING
            && status == Ble.STATUS_SUCCESS
            && characteristic.getUuid().equals(BoardUuids.uuid(BoardUuids.UART_WRITE))) {
            _state = STATE_LIVE;
            _boardState.unlocked = true;
            _spanSolved = _spanVariant;
            _unlockAttempts = 0;
            buildPollList();
        }
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

            // Telemetry arriving is the proof. Latch the span that was in
            // flight so it is used for every subsequent keepalive, and so
            // Diagnostics can report which candidate was correct.
            _spanSolved = _spanVariant;
        }
    }

    // =====================================================================
    // Decoding - all multi-byte values are big-endian
    // =====================================================================

    private function decode(uuid as Ble.Uuid, value as Lang.ByteArray?) as Void {
        if (value == null || value.size() == 0) { return; }

        // Stash the undecoded bytes first, for every characteristic including
        // the ones with no known meaning. This is what Diagnostics shows, and
        // it is deliberately independent of whether the decode below has any
        // idea what this characteristic is.
        captureRaw(uuid, value);

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

    //! Map a UUID back to its short form and store the raw bytes.
    //!
    //! Walks the registered list rather than reversing the UUID, because
    //! Ble.Uuid exposes no way to get its string back. The list is at most 34
    //! entries and this runs on a read completion, not per frame.
    private function captureRaw(uuid as Ble.Uuid, value as Lang.ByteArray) as Void {
        for (var i = 0; i < _registered.size(); i++) {
            var short = _registered[i] as Lang.String;
            if (uuid.equals(BoardUuids.uuid(short))) {
                _boardState.putRaw(short, value);
                return;
            }
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
