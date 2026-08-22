import Foundation

/// Builds GGUF files in memory, for tests that need a real one.
///
/// ## Why not a checked-in model
///
/// Section 90: a repository with a hundred-megabyte model in it is a repository
/// every clone pays for forever. What the parser and the installer actually
/// need is a *header* — the magic, the version, the counts and a metadata table
/// — and that is a few hundred bytes this can generate exactly.
///
/// What it deliberately does not generate is tensor data. Nothing in the app's
/// own validation reads a tensor; llama.cpp does, on a real device, with a real
/// file. Faking weights convincingly enough to load would be faking the one
/// thing this cannot test anyway.
enum GGUFFixture {
    /// A well-formed GGUF header for a plausible small model.
    static func header(
        architecture: String = "qwen3",
        version: UInt32 = 3,
        tensorCount: UInt64 = 254,
        name: String? = "Test Model",
        fileType: UInt32? = 15, // Q4_K_M
        contextLength: Int? = 32768,
        blockCount: Int? = 28,
        headCount: Int? = 16,
        kvHeadCount: Int? = 8,
        embeddingLength: Int? = 2048,
        chatTemplate: String? = nil
    ) -> Data {
        var pairs: [(String, Value)] = [
            ("general.architecture", .string(architecture)),
        ]
        if let name { pairs.append(("general.name", .string(name))) }
        if let fileType { pairs.append(("general.file_type", .uint32(fileType))) }
        if let contextLength {
            pairs.append(("\(architecture).context_length", .uint32(UInt32(contextLength))))
        }
        if let embeddingLength {
            pairs.append(("\(architecture).embedding_length", .uint32(UInt32(embeddingLength))))
        }
        if let blockCount {
            pairs.append(("\(architecture).block_count", .uint32(UInt32(blockCount))))
        }
        if let headCount {
            pairs.append(("\(architecture).attention.head_count", .uint32(UInt32(headCount))))
        }
        if let kvHeadCount {
            pairs.append(("\(architecture).attention.head_count_kv", .uint32(UInt32(kvHeadCount))))
        }
        // A token list, so the parser's array-skipping path is exercised by
        // every fixture rather than by one special test.
        pairs.append(("tokenizer.ggml.tokens", .stringArray(["<s>", "</s>", "hello", "world"])))
        pairs.append(("tokenizer.ggml.scores", .float32Array([0, 0, 0.5, 0.25])))
        if let chatTemplate {
            pairs.append(("tokenizer.chat_template", .string(chatTemplate)))
        }

        var data = Data("GGUF".utf8)
        data.append(uint32: version)
        data.append(uint64: tensorCount)
        data.append(uint64: UInt64(pairs.count))
        for (key, value) in pairs {
            data.append(ggufString: key)
            value.append(to: &data)
        }
        return data
    }

    /// A file whose first four bytes are not "GGUF".
    static func notAModel() -> Data {
        Data("<!DOCTYPE html><html><body>404 Not Found</body></html>".utf8)
    }

    /// Correct magic, a version this app does not read.
    static func unsupportedVersion() -> Data {
        var data = Data("GGUF".utf8)
        data.append(uint32: 1)
        data.append(uint64: 0)
        data.append(uint64: 0)
        return data
    }

    /// Correct magic and version, then nothing. What an interrupted download
    /// leaves behind.
    static func truncated() -> Data {
        var data = Data("GGUF".utf8)
        data.append(uint32: 3)
        return data
    }

    /// Writes bytes to a temporary file the caller is responsible for.
    static func write(_ data: Data, name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).gguf")
        try data.write(to: url)
        return url
    }

    enum Value {
        case string(String)
        case uint32(UInt32)
        case stringArray([String])
        case float32Array([Float])

        func append(to data: inout Data) {
            switch self {
            case .string(let text):
                data.append(uint32: 8)
                data.append(ggufString: text)
            case .uint32(let value):
                data.append(uint32: 4)
                data.append(uint32: value)
            case .stringArray(let values):
                data.append(uint32: 9)
                data.append(uint32: 8)
                data.append(uint64: UInt64(values.count))
                for value in values { data.append(ggufString: value) }
            case .float32Array(let values):
                data.append(uint32: 9)
                data.append(uint32: 6)
                data.append(uint64: UInt64(values.count))
                for value in values { data.append(uint32: value.bitPattern) }
            }
        }
    }
}

extension Data {
    fileprivate mutating func append(uint32 value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    fileprivate mutating func append(uint64 value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    fileprivate mutating func append(ggufString value: String) {
        let bytes = Array(value.utf8)
        append(uint64: UInt64(bytes.count))
        append(contentsOf: bytes)
    }
}
