#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantTools
import Foundation
import SwiftData

/// `ActionPlanRecord` ↔ `SDActionPlan` / `SDAction` / `SDToolResult`.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
enum ActionPlanMapper {
    static let entity = "action plan"

    // MARK: Domain → storage

    static func makeRow(from record: ActionPlanRecord, in context: ModelContext) throws -> SDActionPlan {
        let row = SDActionPlan(id: record.plan.id.rawValue, createdAt: record.plan.createdAt)
        context.insert(row)
        try fill(row, from: record, in: context)
        return row
    }

    /// Rewrites a plan's children.
    ///
    /// Plans are written once and never edited, so replacing the children is
    /// correct here — unlike messages and stages, nothing holds a reference to
    /// an individual action row across saves. Delete-then-insert also keeps a
    /// re-save idempotent instead of doubling the cards under a reply.
    static func fill(
        _ row: SDActionPlan,
        from record: ActionPlanRecord,
        in context: ModelContext
    ) throws {
        for action in row.actions { context.delete(action) }
        for result in row.results { context.delete(result) }
        row.actions = []
        row.results = []

        row.createdAt = record.plan.createdAt

        for (index, action) in record.plan.actions.enumerated() {
            let encoded: Data
            do {
                encoded = try JSONCoding.encoder.encode(action.request)
            } catch {
                throw PersistenceError.mappingFailed(
                    entity: entity,
                    detail: "a \(action.kind.rawValue) request could not be encoded"
                )
            }

            let stored = SDAction(
                id: action.id.rawValue,
                toolKindRaw: action.kind.rawValue,
                originRaw: action.origin.rawValue,
                authorizationRaw: action.authorization.rawValue,
                rationale: action.rationale,
                sourceCallID: action.sourceCallID?.rawValue,
                sequence: index,
                requestJSON: encoded
            )
            stored.plan = row
            context.insert(stored)
        }

        for (index, result) in record.results.enumerated() {
            let outcome = encodeOutcome(result.outcome)
            let stored = SDToolResult(
                id: result.id.rawValue,
                actionID: result.actionID.rawValue,
                kindRaw: result.kind.rawValue,
                outcomeKindRaw: outcome.kind,
                outcomeDetail: outcome.detail,
                message: result.message,
                producedAt: result.producedAt,
                sequence: index
            )
            stored.plan = row
            context.insert(stored)
        }
    }

    // MARK: Storage → domain

    static func makeDomain(from row: SDActionPlan) throws -> ActionPlanRecord {
        guard let conversationID = row.conversation?.id else {
            throw PersistenceError.mappingFailed(
                entity: entity,
                detail: "the plan is not attached to a conversation"
            )
        }

        let actions = try row.actions
            .sorted { $0.sequence < $1.sequence }
            .map(makeAction)
        let results = try row.results
            .sorted { $0.sequence < $1.sequence }
            .map(makeResult)

        return ActionPlanRecord(
            plan: AssistantActionPlan(
                id: ActionPlanID(row.id),
                actions: actions,
                createdAt: row.createdAt
            ),
            results: results,
            conversationID: Conversation.ID(conversationID)
        )
    }

    private static func makeAction(from row: SDAction) throws -> AssistantAction {
        let request: ToolRequest
        do {
            request = try JSONCoding.decoder.decode(ToolRequest.self, from: row.requestJSON)
        } catch {
            throw PersistenceError.mappingFailed(
                entity: entity,
                detail: "a stored \(row.toolKindRaw) request could not be read"
            )
        }

        return AssistantAction(
            id: AssistantAction.ID(row.id),
            request: request,
            origin: try decodeEnum(
                ActionOrigin.self, from: row.originRaw, entity: entity, field: "origin"
            ),
            authorization: try decodeEnum(
                ToolAuthorization.self,
                from: row.authorizationRaw,
                entity: entity,
                field: "authorization"
            ),
            rationale: row.rationale,
            sourceCallID: row.sourceCallID.map { ToolCallID($0) }
        )
    }

    private static func makeResult(from row: SDToolResult) throws -> ToolResult {
        ToolResult(
            id: ToolResult.ID(row.id),
            actionID: AssistantAction.ID(row.actionID),
            kind: try decodeEnum(ToolKind.self, from: row.kindRaw, entity: entity, field: "tool kind"),
            outcome: try decodeOutcome(row),
            message: row.message,
            producedAt: row.producedAt
        )
    }

    // MARK: Outcome

    /// `ToolOutcome` carries at most one string, so a discriminator and a
    /// detail column cover it. The discriminator is what the UI badges a
    /// restored card with — `simulated` has to survive, or a reloaded
    /// transcript would start implying a phone did something it did not.
    private static func encodeOutcome(_ outcome: ToolOutcome) -> (kind: String, detail: String?) {
        switch outcome {
        case .executed:
            return (OutcomeKindColumn.executed, nil)
        case .simulated(let platform):
            return (OutcomeKindColumn.simulated, platform)
        case .awaitingConfirmation:
            return (OutcomeKindColumn.awaitingConfirmation, nil)
        case .denied(let reason):
            return (OutcomeKindColumn.denied, reason)
        case .failed(let reason):
            return (OutcomeKindColumn.failed, reason)
        case .unsupported(let reason):
            return (OutcomeKindColumn.unsupported, reason)
        }
    }

    private static func decodeOutcome(_ row: SDToolResult) throws -> ToolOutcome {
        switch row.outcomeKindRaw {
        case OutcomeKindColumn.executed:
            return .executed
        case OutcomeKindColumn.simulated:
            return .simulated(platform: row.outcomeDetail ?? "an unnamed service")
        case OutcomeKindColumn.awaitingConfirmation:
            return .awaitingConfirmation
        case OutcomeKindColumn.denied:
            return .denied(reason: row.outcomeDetail ?? "No reason was recorded.")
        case OutcomeKindColumn.failed:
            return .failed(reason: row.outcomeDetail ?? "No reason was recorded.")
        case OutcomeKindColumn.unsupported:
            return .unsupported(reason: row.outcomeDetail ?? "No reason was recorded.")
        default:
            throw PersistenceError.mappingFailed(entity: entity, detail: "unrecognised outcome")
        }
    }
}

#endif
