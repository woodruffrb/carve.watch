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

    //! A frame is valid if it is 20 bytes with a correct trailing checksum.
    //!
    //! Deliberately does NOT require a "CRX" signature. A real challenge from
    //! a board on firmware 4165 reads:
    //!
    //!   09 8E 56 6D 05 3B 63 6D C9 A7 20 04 55 29 80 19 80 5A A7 5E
    //!
    //! - no CRX anywhere in it, and byte 19 is a correct XOR of bytes 0..18.
    //! An earlier version required the signature on the challenge, taken from
    //! a summarised community write-up, and rejected every frame the board
    //! sent. The signature belongs to the response, not the challenge.
    //!
    //! The checksum matching is what proves the framing is right: a
    //! misaligned 20-byte window would not produce a valid one by chance.
    function isChallenge(buf as Lang.ByteArray?) as Lang.Boolean {
        if (buf == null || buf.size() < FRAME_LEN) {
            return false;
        }
        return true;
    }

    //! Which bytes of the challenge feed the MD5.
    //!
    //! This is the one part of the handshake still genuinely unknown. Rather
    //! than pick one and require a rebuild-and-reflash cycle per guess,
    //! BoardLink cycles through these on successive challenges and keeps
    //! whichever one produces telemetry.
    //! A variant encodes both unknowns: which bytes are hashed, and in which
    //! order they are concatenated with the key. Order matters to MD5 and
    //! there was never any evidence for one over the other, so both are
    //! searched rather than assumed.
    //!
    //!   variant / 2  -> span    0..3
    //!   variant % 2  -> order   0 = span then key, 1 = key then span
    const SPAN_PAYLOAD    = 0;   // bytes 3..18  (16) - the documented reading
    const SPAN_FULL_FRAME = 1;   // bytes 0..19  (20)
    const SPAN_FIRST16    = 2;   // bytes 0..15  (16)
    const SPAN_DATA19     = 3;   // bytes 0..18  (19) - everything but checksum
    const SPAN_COUNT      = 4;
    const VARIANT_COUNT   = 8;

    function spanBytes(challenge as Lang.ByteArray, variant as Lang.Number) as Lang.ByteArray {
        var span = variant / 2;
        if (span == SPAN_FULL_FRAME) { return challenge.slice(0, FRAME_LEN); }
        if (span == SPAN_FIRST16)    { return challenge.slice(0, 16); }
        if (span == SPAN_DATA19)     { return challenge.slice(0, FRAME_LEN - 1); }
        return challenge.slice(3, 19);
    }

    function keyFirst(variant as Lang.Number) as Lang.Boolean {
        return (variant % 2) == 1;
    }

    //! Build the 20-byte answer: "CRX" + MD5 + XOR checksum.
    //!
    //! The signature stays on the response - that is what the documented
    //! procedure describes, and nothing observed contradicts it.
    function buildResponse(challenge as Lang.ByteArray?, variant as Lang.Number) as Lang.ByteArray? {
        if (!isChallenge(challenge)) {
            return null;
        }

        var hash = new Cryptography.Hash({ :algorithm => Cryptography.HASH_MD5 });
        var span = spanBytes(challenge, variant);
        if (keyFirst(variant)) {
            hash.update(KEY);
            hash.update(span);
        } else {
            hash.update(span);
            hash.update(KEY);
        }
        var digest = hash.digest();

        var frame = [0x43, 0x52, 0x58]b.addAll(digest);
        return frame.add(xorChecksum(frame));
    }

    //! XOR of every byte. Used both to build our checksum and to verify the
    //! board's, which is what proves a 20-byte window is correctly aligned.
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
