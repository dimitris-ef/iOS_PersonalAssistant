import Foundation

/// What the app could read out of a GGUF file's own header.
///
/// ## Why this exists when llama.cpp can read GGUF perfectly well
///
/// Because the answer to "is this file a model" must arrive *before* anything
/// tries to load it, and on builds where llama.cpp is not linked at all.
/// Section 24 asks for the file to be inspected rather than trusted for having
/// a `.gguf` on the end, and a 2 GB HTML error page named `model.gguf` is a
/// completely ordinary thing for a broken CDN to hand back.
///
/// It is also what section 116 needs: the catalog says a file is `qwen3`, and
/// this is how the app finds out whether it is.
///
/// ## What it deliberately does not do
///
/// It reads the header and the metadata table. It does not read tensors, does
/// not validate quantization blocks, and does not attempt to prove the model
/// will produce sensible output. Those are llama.cpp's job at load time, and a
/// second half-implementation of them here would be a second thing to be wrong.
public struct GGUFHeader: Hashable, Sendable {
    /// 2 or 3 in practice.
    public var version: UInt32
    public var tensorCount: UInt64
    public var metadataCount: UInt64
    /// `general.architecture` — "qwen3", "llama", "gemma3", "phi3".
    public var architecture: String?
    /// `general.name`, which is whoever-built-it's label and often absent.
    public var name: String?
    /// `general.file_type`, the `llama_ftype` enum value. Maps to a
    /// quantization name via ``GGUFFileType``.
    public var fileType: UInt32?
    /// `<architecture>.context_length` — what the weights were trained for.
    public var trainedContextLength: Int?
    /// `<architecture>.block_count`, `.attention.head_count_kv` and
    /// `.attention.key_length`, when present. Together these give a real KV
    /// cache size instead of an estimate from parameter count.
    public var blockCount: Int?
    public var kvHeadCount: Int?
    public var keyLength: Int?
    public var embeddingLength: Int?
    /// True when the file carries `tokenizer.chat_template`.
    public var hasChatTemplate: Bool

    public init(
        version: UInt32,
        tensorCount: UInt64,
        metadataCount: UInt64,
        architecture: String? = nil,
        name: String? = nil,
        fileType: UInt32? = nil,
        trainedContextLength: Int? = nil,
        blockCount: Int? = nil,
        kvHeadCount: Int? = nil,
        keyLength: Int? = nil,
        embeddingLength: Int? = nil,
        hasChatTemplate: Bool = false
    ) {
        self.version = version
        self.tensorCount = tensorCount
        self.metadataCount = metadataCount
        self.architecture = architecture
        self.name = name
        self.fileType = fileType
        self.trainedContextLength = trainedContextLength
        self.blockCount = blockCount
        self.kvHeadCount = kvHeadCount
        self.keyLength = keyLength
        self.embeddingLength = embeddingLength
        self.hasChatTemplate = hasChatTemplate
    }

    /// The quantization name implied by `general.file_type`.
    public var quantization: LocalModelQuantization? {
        fileType.flatMap { GGUFFileType.quantization(for: $0) }
    }

    /// Bytes of KV cache per token, when the header said enough to work it out.
    ///
    /// `2 * layers * kv_heads * head_dim * 2 bytes` — K and V, one f16 each.
    /// Returns nil rather than guessing when a field is missing; the estimator
    /// has its own conservative fallback and would rather use that than a
    /// number derived from half the facts.
    public var kvCacheBytesPerToken: Int? {
        guard let blockCount, let kvHeadCount, let keyLength else { return nil }
        guard blockCount > 0, kvHeadCount > 0, keyLength > 0 else { return nil }
        return 2 * blockCount * kvHeadCount * keyLength * 2
    }
}

/// Why a file is not a usable GGUF.
public enum GGUFReadError: Error, Hashable, Sendable, CustomStringConvertible {
    case unreadable(reason: String)
    /// The first four bytes were not "GGUF".
    case notGGUF
    /// GGUF v1 used 32-bit lengths and is not supported.
    case unsupportedVersion(UInt32)
    /// The header claims something the file cannot contain — a metadata table
    /// longer than the file, a string of implausible length.
    case malformed(reason: String)

    public var description: String {
        switch self {
        case .unreadable(let reason): return "The model file could not be read: \(reason)"
        case .notGGUF: return "This file is not a GGUF model."
        case .unsupportedVersion(let version): return "GGUF version \(version) is not supported."
        case .malformed(let reason): return "The model file is damaged: \(reason)"
        }
    }
}

/// Reads the metadata block at the front of a GGUF file.
///
/// ## The format, briefly
///
/// ```
/// magic        "GGUF"           4 bytes
/// version      uint32
/// tensor_count uint64
/// kv_count     uint64
/// kv pairs     key (uint64 length + utf8), value_type (uint32), value
/// ```
///
/// Values are little-endian, arrays carry an element type and a count, and
/// strings are length-prefixed. That is the whole grammar, which is why parsing
/// it here is a hundred lines rather than a dependency.
///
/// ## Bounded on purpose
///
/// Only a prefix of the file is read, and the walk stops at the first thing
/// that does not make sense. A header that claims a four-billion-character
/// string is a corrupt header, and the parser has to say so rather than try to
/// allocate it — this code runs on a phone, against a file that arrived from
/// the internet.
public enum GGUFReader {
    /// GGUF magic, little-endian: 'G','G','U','F'.
    static let magic: [UInt8] = [0x47, 0x47, 0x55, 0x46]

    /// How much of the file to read. Metadata sits at the front and is
    /// kilobytes for a normal model; the tokenizer vocabulary can push it into
    /// megabytes, so the window is generous but finite.
    public static let inspectionWindowBytes = 32 * 1024 * 1024

    /// Longest string the parser will accept from a header. Chat templates run
    /// to a few kilobytes; anything past this is a corrupt length field.
    static let maximumStringBytes = 1 << 20

    /// Largest array the parser will walk. Token vocabularies are the big one
    /// and top out in the low hundreds of thousands.
    static let maximumArrayElements = 4_000_000

    /// Reads the header of a file on disk.
    public static func read(contentsOf url: URL) throws -> GGUFHeader {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw GGUFReadError.unreadable(reason: error.localizedDescription)
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: inspectionWindowBytes) ?? Data()
        } catch {
            throw GGUFReadError.unreadable(reason: error.localizedDescription)
        }
        return try read(data)
    }

    /// Reads a header out of bytes already in memory. The entry point tests use.
    public static func read(_ data: Data) throws -> GGUFHeader {
        var cursor = Cursor(data)

        guard let magicBytes = cursor.bytes(4), Array(magicBytes) == magic else {
            throw GGUFReadError.notGGUF
        }
        guard let version: UInt32 = cursor.integer() else {
            throw GGUFReadError.malformed(reason: "truncated version")
        }
        // v1 length-prefixed with uint32 and is long gone from circulation.
        // Rejecting it is honest; silently mis-parsing it would not be.
        guard version == 2 || version == 3 else {
            throw GGUFReadError.unsupportedVersion(version)
        }
        guard
            let tensorCount: UInt64 = cursor.integer(),
            let metadataCount: UInt64 = cursor.integer()
        else {
            throw GGUFReadError.malformed(reason: "truncated header counts")
        }
        guard metadataCount <= 100_000 else {
            throw GGUFReadError.malformed(reason: "implausible metadata count")
        }

        var header = GGUFHeader(
            version: version,
            tensorCount: tensorCount,
            metadataCount: metadataCount
        )
        var values: [String: GGUFValue] = [:]

        for _ in 0..<metadataCount {
            guard let key = try cursor.string() else {
                // Running out of window is not corruption: a big vocabulary can
                // legitimately exceed it. What has been read stays valid.
                break
            }
            guard let rawType: UInt32 = cursor.integer(),
                  let type = GGUFValueType(rawValue: rawType)
            else {
                throw GGUFReadError.malformed(reason: "unknown metadata type for \(key)")
            }
            guard let value = try cursor.value(of: type) else { break }
            // Only what is used is kept. A token vocabulary is hundreds of
            // thousands of strings and there is no reason to hold it.
            if Self.interestingKeys.contains(where: { key.hasSuffix($0) || key == $0 }) {
                values[key] = value
            }
            if key == "tokenizer.chat_template" {
                header.hasChatTemplate = true
            }
        }

        header.architecture = values["general.architecture"]?.stringValue
        header.name = values["general.name"]?.stringValue
        header.fileType = values["general.file_type"]?.uint32Value

        if let architecture = header.architecture {
            header.trainedContextLength = values["\(architecture).context_length"]?.intValue
            header.blockCount = values["\(architecture).block_count"]?.intValue
            header.embeddingLength = values["\(architecture).embedding_length"]?.intValue
            header.kvHeadCount = values["\(architecture).attention.head_count_kv"]?.intValue
            header.keyLength = values["\(architecture).attention.key_length"]?.intValue

            // Most models omit `key_length` because it is embedding_length /
            // head_count. Deriving it is worth doing: without it there is no KV
            // cache figure at all, and a KV figure is the difference between a
            // memory estimate and a guess.
            if header.keyLength == nil,
               let embedding = header.embeddingLength,
               let heads = values["\(architecture).attention.head_count"]?.intValue,
               heads > 0 {
                header.keyLength = embedding / heads
            }
            // Likewise: no GQA recorded means every head has its own KV.
            if header.kvHeadCount == nil {
                header.kvHeadCount = values["\(architecture).attention.head_count"]?.intValue
            }
        }

        return header
    }

    /// Keys worth keeping. Everything else is walked past without allocating.
    static let interestingKeys: Set<String> = [
        "general.architecture",
        "general.name",
        "general.file_type",
        ".context_length",
        ".block_count",
        ".embedding_length",
        ".attention.head_count",
        ".attention.head_count_kv",
        ".attention.key_length",
    ]
}

/// The value types GGUF defines, straight from `gguf.h`.
enum GGUFValueType: UInt32 {
    case uint8 = 0
    case int8 = 1
    case uint16 = 2
    case int16 = 3
    case uint32 = 4
    case int32 = 5
    case float32 = 6
    case bool = 7
    case string = 8
    case array = 9
    case uint64 = 10
    case int64 = 11
    case float64 = 12

    /// Bytes for the fixed-width types; nil for string and array.
    var scalarWidth: Int? {
        switch self {
        case .uint8, .int8, .bool: return 1
        case .uint16, .int16: return 2
        case .uint32, .int32, .float32: return 4
        case .uint64, .int64, .float64: return 8
        case .string, .array: return nil
        }
    }
}

/// A metadata value, in the few shapes anything here cares about.
enum GGUFValue: Hashable {
    case integer(Int64)
    case unsigned(UInt64)
    case double(Double)
    case boolean(Bool)
    case text(String)
    /// Arrays are recorded as their length only — nothing here needs elements.
    case arrayOfCount(Int)

    var stringValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): return Int(value)
        case .unsigned(let value): return value <= UInt64(Int.max) ? Int(value) : nil
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    var uint32Value: UInt32? {
        guard let value = intValue, value >= 0, value <= Int(UInt32.max) else { return nil }
        return UInt32(value)
    }
}

/// A bounds-checked read head over the bytes.
///
/// Every accessor returns nil at the end of the window instead of trapping.
/// That matters more than it looks: the input is an untrusted file, the window
/// is a fixed prefix, and a parser that traps on a short read is a parser that
/// crashes the app when a download is interrupted.
private struct Cursor {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    var remaining: Int { max(0, data.count - offset) }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        let start = data.startIndex + offset
        let slice = data[start..<(start + count)]
        offset += count
        return Data(slice)
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, remaining >= count else { return false }
        offset += count
        return true
    }

    /// Reads a little-endian fixed-width integer.
    ///
    /// Assembled byte by byte rather than by loading and byte-swapping, so the
    /// result is correct on either endianness without the call site having to
    /// know which one it is on. (Which is also why there is no `littleEndian:`
    /// conversion afterwards — the value is already in host order.)
    mutating func integer<T: FixedWidthInteger>() -> T? {
        guard let raw = bytes(MemoryLayout<T>.size) else { return nil }
        var value: T = 0
        for (index, byte) in raw.enumerated() {
            value |= T(truncatingIfNeeded: byte) << (8 * index)
        }
        return value
    }

    mutating func float32() -> Float? {
        guard let bits: UInt32 = integer() else { return nil }
        return Float(bitPattern: bits)
    }

    mutating func float64() -> Double? {
        guard let bits: UInt64 = integer() else { return nil }
        return Double(bitPattern: bits)
    }

    /// A GGUF string: uint64 byte length, then UTF-8.
    mutating func string() throws -> String? {
        guard let length: UInt64 = integer() else { return nil }
        guard length <= UInt64(GGUFReader.maximumStringBytes) else {
            throw GGUFReadError.malformed(reason: "string length \(length) is implausible")
        }
        guard let raw = bytes(Int(length)) else { return nil }
        // Lossy on purpose. A single bad byte in a model's display name is not
        // a reason to reject a two-gigabyte file that is otherwise fine.
        return String(decoding: raw, as: UTF8.self)
    }

    /// Reads one value of the given type, or nil at the end of the window.
    mutating func value(of type: GGUFValueType) throws -> GGUFValue? {
        switch type {
        case .uint8:
            return (integer() as UInt8?).map { .unsigned(UInt64($0)) }
        case .int8:
            return (integer() as Int8?).map { .integer(Int64($0)) }
        case .uint16:
            return (integer() as UInt16?).map { .unsigned(UInt64($0)) }
        case .int16:
            return (integer() as Int16?).map { .integer(Int64($0)) }
        case .uint32:
            return (integer() as UInt32?).map { .unsigned(UInt64($0)) }
        case .int32:
            return (integer() as Int32?).map { .integer(Int64($0)) }
        case .uint64:
            return (integer() as UInt64?).map { .unsigned($0) }
        case .int64:
            return (integer() as Int64?).map { .integer($0) }
        case .float32:
            return float32().map { .double(Double($0)) }
        case .float64:
            return float64().map { .double($0) }
        case .bool:
            return (integer() as UInt8?).map { .boolean($0 != 0) }
        case .string:
            return try string().map { .text($0) }

        case .array:
            guard let rawElement: UInt32 = integer(),
                  let element = GGUFValueType(rawValue: rawElement),
                  let count: UInt64 = integer()
            else { return nil }
            guard count <= UInt64(GGUFReader.maximumArrayElements) else {
                throw GGUFReadError.malformed(reason: "array of \(count) elements is implausible")
            }
            let elementCount = Int(count)

            // Fixed-width elements are skipped in one jump. A 150,000-token
            // vocabulary of f32 scores is 600 KB, and walking it element by
            // element to throw all of it away would be the slowest part of
            // opening a model.
            if let width = element.scalarWidth {
                guard skip(width * elementCount) else { return nil }
                return .arrayOfCount(elementCount)
            }

            for _ in 0..<elementCount {
                guard try value(of: element) != nil else { return nil }
            }
            return .arrayOfCount(elementCount)
        }
    }
}

/// `general.file_type` values, from `llama_ftype` in `llama.h`.
///
/// Only a mapping for display and for sanity-checking the catalog: llama.cpp
/// decides what it can load, not this table. An unknown value produces nil,
/// which reads as "the quantization was not recorded" rather than as a reason
/// to refuse the file.
public enum GGUFFileType {
    public static func quantization(for value: UInt32) -> LocalModelQuantization? {
        switch value {
        case 0: return "F32"
        case 1: return "F16"
        case 2: return "Q4_0"
        case 3: return "Q4_1"
        case 7: return "Q8_0"
        case 8: return "Q5_0"
        case 9: return "Q5_1"
        case 10: return "Q2_K"
        case 11: return "Q3_K_S"
        case 12: return "Q3_K_M"
        case 13: return "Q3_K_L"
        case 14: return "Q4_K_S"
        case 15: return "Q4_K_M"
        case 16: return "Q5_K_S"
        case 17: return "Q5_K_M"
        case 18: return "Q6_K"
        case 19: return "IQ2_XXS"
        case 20: return "IQ2_XS"
        case 21: return "Q2_K_S"
        case 22: return "IQ3_XS"
        case 23: return "IQ3_XXS"
        case 24: return "IQ1_S"
        case 25: return "IQ4_NL"
        case 26: return "IQ3_S"
        case 27: return "IQ3_M"
        case 28: return "IQ2_S"
        case 29: return "IQ2_M"
        case 30: return "IQ4_XS"
        case 31: return "IQ1_M"
        case 32: return "BF16"
        case 36: return "TQ1_0"
        case 37: return "TQ2_0"
        case 38: return "MXFP4_MOE"
        default: return nil
        }
    }
}
