import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// SHA-256 over a file that is far too big to hold in memory.
///
/// ## Why there are two implementations
///
/// CryptoKit is present on every Apple platform this app ships to, is hardware
/// accelerated, and hashes a 2 GB file in a couple of seconds. It does not
/// exist on Linux or Windows, where the memory architecture, the download
/// manager and every test around them are developed and run.
///
/// So: CryptoKit where it exists, and a plain implementation where it does not
/// — with a test that hashes the NIST vectors through whichever one is
/// compiled, so the fallback cannot quietly rot into producing different
/// answers from the real one.
///
/// ## Why hashing at all
///
/// Section 22. A model file arrives over the internet from a host this app does
/// not control, and "the bytes I have are the bytes that were published" is not
/// a question a file extension can answer. When the catalog declares a checksum
/// this is what enforces it; when it does not, this is still what gets recorded
/// so a later integrity check has something to compare against.
public enum SHA256Hash {
    /// How much is read at a time. Large enough that a 2 GB file is a few
    /// thousand reads, small enough that the buffer is never a memory problem.
    static let chunkBytes = 4 * 1024 * 1024

    /// Lowercase hex digest of a file, or nil if it cannot be read.
    ///
    /// Streaming, never `Data(contentsOf:)`. Loading a multi-gigabyte model
    /// into memory to hash it would use more memory than running it.
    public static func hexDigest(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var context = Context()
        while true {
            let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
            if chunk.isEmpty { break }
            context.update(chunk)
        }
        return context.finalizeHex()
    }

    /// Lowercase hex digest of bytes in memory.
    public static func hexDigest(of data: Data) -> String {
        var context = Context()
        context.update(data)
        return context.finalizeHex()
    }

    /// Case-insensitive comparison of two hex digests.
    ///
    /// Catalogs are written by hand and `SHA256:` prefixes and capital letters
    /// both happen; neither should read as a corrupt download.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    /// True when a string looks like a SHA-256 digest at all.
    public static func isWellFormed(_ value: String) -> Bool {
        let normalized = normalize(value)
        return normalized.count == 64 && normalized.allSatisfy(\.isHexDigit)
    }

    /// Strips the casing, whitespace and `sha256:` prefix that published
    /// checksums arrive with, so two digests can be compared as written.
    ///
    /// Public because callers store the normalized form: a checksum mismatch is
    /// reported with what was expected, and reporting the raw catalog string
    /// there would show `SHA256:AB…` against `ab…` and look like a different
    /// bug than the one that happened.
    public static func normalize(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("sha256:") { text.removeFirst("sha256:".count) }
        return text
    }

    /// Incremental hashing, over whichever implementation this build has.
    struct Context {
        #if canImport(CryptoKit)
        private var hasher = CryptoKit.SHA256()

        mutating func update(_ data: Data) { hasher.update(data: data) }

        mutating func finalizeHex() -> String {
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        #else
        private var portable = PortableSHA256()

        mutating func update(_ data: Data) { portable.update(data) }

        mutating func finalizeHex() -> String { portable.finalizeHex() }
        #endif
    }
}

/// SHA-256 as FIPS 180-4 defines it.
///
/// Straight from the specification, with no attempt at cleverness: where this
/// is the implementation actually used, it runs on a development machine rather
/// than on the hot path of a phone.
///
/// It is *compiled* everywhere, including where CryptoKit supersedes it, and
/// that is deliberate: it lets the test suite hash the same input through both
/// and assert they agree. A fallback that is only built on the platform nobody
/// runs the tests on is a fallback that is wrong and will not be found out.
struct PortableSHA256 {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer: [UInt8] = []
    private var totalBytes: UInt64 = 0

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    mutating func update(_ data: Data) {
        totalBytes += UInt64(data.count)
        buffer.append(contentsOf: data)
        var offset = 0
        while buffer.count - offset >= 64 {
            compress(Array(buffer[offset..<(offset + 64)]))
            offset += 64
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    mutating func finalizeHex() -> String {
        // Padding: one 0x80 byte, zeros, then the message length in bits as a
        // big-endian 64-bit integer, filling to a 64-byte boundary.
        let bitLength = totalBytes &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 { buffer.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        var offset = 0
        while offset < buffer.count {
            compress(Array(buffer[offset..<(offset + 64)]))
            offset += 64
        }
        buffer.removeAll()
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let base = index * 4
            w[index] = UInt32(block[base]) << 24
                | UInt32(block[base + 1]) << 16
                | UInt32(block[base + 2]) << 8
                | UInt32(block[base + 3])
        }
        for index in 16..<64 {
            let s0 = rotate(w[index - 15], 7) ^ rotate(w[index - 15], 18) ^ (w[index - 15] >> 3)
            let s1 = rotate(w[index - 2], 17) ^ rotate(w[index - 2], 19) ^ (w[index - 2] >> 10)
            w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for index in 0..<64 {
            let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ Self.k[index] &+ w[index]
            let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj

            h = g; g = f; f = e
            e = d &+ temp1
            d = c; c = b; b = a
            a = temp1 &+ temp2
        }

        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }

    private func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
