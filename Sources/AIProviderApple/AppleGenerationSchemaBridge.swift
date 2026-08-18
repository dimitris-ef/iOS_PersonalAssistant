#if canImport(FoundationModels)

import AssistantAI
import AssistantDomain
import Foundation
import FoundationModels

/// Translates the application's tool schemas into Foundation Models schemas,
/// and the framework's generated arguments back into plain JSON.
///
/// This bridge is the reason there is exactly one tool adapter type rather than
/// one per tool. Apple's `Tool` protocol has an associated `Arguments` type,
/// which normally means a `@Generable` struct written by hand for every tool —
/// a second, parallel definition of every tool the app already declares, and
/// the "three sources of truth" problem the architecture exists to avoid.
///
/// `DynamicGenerationSchema` is the way out: schemas can be built at runtime
/// from `ToolCatalog`, so the catalogue stays the single source of truth and
/// adding a tool needs no Apple-specific code at all.
@available(iOS 26.0, macOS 26.0, *)
enum AppleGenerationSchemaBridge {

    /// The schema Foundation Models will constrain a tool's arguments to.
    static func generationSchema(for tool: AIToolSchema) throws -> GenerationSchema {
        let root = dynamicSchema(for: tool.parameters, name: rootName(for: tool.name))
        // Nested objects are inlined into their parent rather than registered
        // as named dependencies. The catalogue's schemas are shallow and none
        // is referenced twice, so naming them would add ceremony and a second
        // chance to get a name wrong.
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// One JSON Schema node as its Foundation Models counterpart.
    static func dynamicSchema(for schema: JSONSchema, name: String) -> DynamicGenerationSchema {
        switch schema {
        case .string:
            return DynamicGenerationSchema(type: String.self)

        case .integer:
            return DynamicGenerationSchema(type: Int.self)

        case .number:
            return DynamicGenerationSchema(type: Double.self)

        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)

        case .enumeration(let values, _):
            // Constrained generation rather than a hopeful description: the
            // model cannot emit a value outside the list, so the app's decoder
            // never has to reject one.
            return DynamicGenerationSchema(type: String.self, guides: [.anyOf(values)])

        case .array(let items, _):
            return DynamicGenerationSchema(
                arrayOf: dynamicSchema(for: items, name: name + "_item")
            )

        case .object(let properties, let required, let description):
            let ordered = properties.sorted { $0.key < $1.key }
            return DynamicGenerationSchema(
                name: name,
                description: description,
                properties: ordered.map { key, value in
                    DynamicGenerationSchema.Property(
                        name: key,
                        description: describe(value),
                        schema: dynamicSchema(for: value, name: name + "_" + key),
                        // Anything not named in `required` is genuinely
                        // optional. Marking everything required would make the
                        // model invent values for fields the user never
                        // mentioned, which is worse than a missing field the
                        // app already knows how to default.
                        isOptional: !required.contains(key)
                    )
                }
            )
        }
    }

    /// What to tell the model about one property.
    ///
    /// String formats are folded in here rather than expressed as a schema
    /// constraint. Foundation Models can constrain a string with a regex, but
    /// `ToolRequestDecoder` is what actually parses these values, and a pattern
    /// that disagreed with the decoder by one character would reject arguments
    /// the app would happily have accepted. Telling the model the shape in
    /// words keeps one parser authoritative.
    private static func describe(_ schema: JSONSchema) -> String? {
        let text: String?
        let hint: String?

        switch schema {
        case .string(let description, let format):
            text = description
            switch format {
            case .dateTime: hint = "An ISO-8601 date and time, for example 2026-03-14T09:30:00Z."
            case .uuid: hint = "A UUID string."
            case .duration: hint = "An ISO-8601 duration, for example PT45M."
            case .none: hint = nil
            }
        case .integer(let description),
             .number(let description),
             .boolean(let description):
            text = description
            hint = nil
        case .enumeration(let values, let description):
            text = description
            hint = "One of: " + values.joined(separator: ", ") + "."
        case .array(_, let description):
            text = description
            hint = nil
        case .object(_, _, let description):
            text = description
            hint = nil
        }

        let parts = [text, hint].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// A schema name derived from the tool name.
    ///
    /// Tool names come from `ToolKind`, so they are already identifier-shaped,
    /// but the sanitising is cheap and means a future tool name with a space or
    /// a dash cannot produce an invalid schema at runtime on a user's phone.
    private static func rootName(for toolName: String) -> String {
        let cleaned = toolName.map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let name = String(cleaned)
        return name.isEmpty ? "Arguments" : name
    }
}

// MARK: - Generated content back to JSON

@available(iOS 26.0, macOS 26.0, *)
extension AppleGenerationSchemaBridge {

    /// The framework's structured output as the application's plain JSON.
    ///
    /// Goes through `jsonString` rather than walking `GeneratedContent.Kind`.
    /// The app's `JSONValue` is precisely "arbitrary JSON", the framework
    /// already knows how to write that, and a hand-rolled tree walk would be
    /// one more thing to keep in step with a type Apple owns.
    static func jsonValue(from content: GeneratedContent) throws -> JSONValue {
        let json = content.jsonString
        guard let data = json.data(using: .utf8) else {
            throw AppleFoundationModelsError.unreadableToolArguments
        }
        do {
            return try JSONCoding.decoder.decode(JSONValue.self, from: data)
        } catch {
            throw AppleFoundationModelsError.unreadableToolArguments
        }
    }

    /// The reverse, for replaying a previous turn's tool calls into a new
    /// session's transcript.
    static func generatedContent(from value: JSONValue) throws -> GeneratedContent {
        let data = try JSONCoding.encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AppleFoundationModelsError.unreadableToolArguments
        }
        return try GeneratedContent(json: json)
    }
}

#endif
