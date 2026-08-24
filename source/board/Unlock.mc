using Toybox.Cryptography;
using Toybox.Lang;

//! The keepalive handshake.
//!
//! Newer board firmware freezes its telemetry characteristics unless the
//! client answers a challenge at least every 24 seconds. The board emits a
//! 20-byte frame on the UART read characteristic; we answer on UART write.
//!
//! Frame layout (20 bytes):
//!
//!     0..2    "CRX"  signature
//!     3..18   16-byte payload
//!     19      XOR checksum of bytes 0..18
//!
//! Response has the same shape, with the MD5 digest in place of the payload.
module Unlock {

    //! Static key recovered by the community from the stock application.
    var KEY as Lang.ByteArray = [
        0xd9, 0x25, 0x5f, 0x0f, 0x23, 0x35, 0x4e, 0x19,
        0xba, 0x73, 0x9c, 0xcd, 0xc4, 0xa9, 0x17, 0x65
    ]b;

    var SIGNATURE as Lang.ByteArray = [0x43, 0x52, 0x58]b;   // "CRX"
    const FRAME_LEN = 20;

    // The source documentation says to hash "the challenge bytes + password"
    // without pinning down whether that means the 16-byte payload or the whole
    // 20-byte frame. Payload is the reading both community implementations
    // appear to use, so it is the default.
    //
    // If the board rejects the response on hardware - BoardLink reports
    // STATE_UNLOCK_REJECTED after three attempts - change this to
    // SPAN_FULL_FRAME and re-test. That is the entire fix.
    const SPAN_PAYLOAD    = 0;
    const SPAN_FULL_FRAME = 1;
    const MD5_SPAN = SPAN_PAYLOAD;

    //! True when buf is a complete, well-formed challenge frame.
    function isChallenge(buf as Lang.ByteArray?) as Lang.Boolean {
        if (buf == null || buf.size() < FRAME_LEN) {
            return false;
        }
        return buf[0] == 0x43 && buf[1] == 0x52 && buf[2] == 0x58;
    }

    //! Build the 20-byte answer, or null if the frame is not a valid challenge.
    function buildResponse(challenge as Lang.ByteArray?) as Lang.ByteArray? {
        if (!isChallenge(challenge)) {
            return null;
        }

        var hashed = (MD5_SPAN == SPAN_FULL_FRAME)
            ? challenge.slice(0, FRAME_LEN)
            : challenge.slice(3, 19);

        var hash = new Cryptography.Hash({ :algorithm => Cryptography.HASH_MD5 });
        hash.update(hashed);
        hash.update(KEY);
        var digest = hash.digest();          // 16 bytes

        // Built from a fresh literal rather than from SIGNATURE. ByteArray
        // add/addAll return new arrays rather than mutating, so reusing
        // SIGNATURE would be safe - but if that ever stopped being true the
        // constant would grow by 17 bytes on every keepalive, and the failure
        // would not show up until well into a ride.
        var frame = [0x43, 0x52, 0x58]b.addAll(digest);
        return frame.add(xorChecksum(frame));
    }

    //! XOR of every byte. Used both to build our checksum and to sanity-check
    //! the board's, which is how a half-received frame gets caught.
    function xorChecksum(bytes as Lang.ByteArray) as Lang.Number {
        var acc = 0;
        for (var i = 0; i < bytes.size(); i++) {
            acc = acc ^ bytes[i];
        }
        return acc & 0xFF;
    }

    //! Verify the challenge's own trailing checksum. A mismatch means the
    //! notification was split across packets and reassembly went wrong.
    function frameIsIntact(challenge as Lang.ByteArray?) as Lang.Boolean {
        if (!isChallenge(challenge)) {
            return false;
        }
        return xorChecksum(challenge.slice(0, FRAME_LEN - 1))
            == challenge[FRAME_LEN - 1];
    }
}
