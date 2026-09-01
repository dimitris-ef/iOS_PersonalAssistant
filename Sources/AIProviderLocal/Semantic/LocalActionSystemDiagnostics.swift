import AssistantAI
import AssistantDomain
import Foundation

/// Writes the action system's decisions into the Local AI diagnostic log.
///
/// ## Why a bridge rather than a dependency
///
/// The action system must not depend on any one provider (section 7), and the
/// only diagnostic logger this app has lives with the local model system —
/// where it belongs, because most of what it records is native inference.
/// Rather than drag that logger up into `AssistantAI`, the action system
/// declares a small sink protocol and this translates it.
///
/// The practical payoff: a tester exporting Local AI diagnostics after "the
/// reminder didn't work" gets the router's decision, which backend ran, and
/// where it stopped, on the same timeline as the decode breadcrumbs — rather
/// than two logs that have to be lined up by eye.
///
/// ## What it cannot leak
///
/// Everything it writes comes from `ActionSystemDiagnosticEvent`, whose cases
/// carry only symbols and app-assigned identifiers, into
/// `LocalInferenceMetadata`, whose keys are a closed enum with nothing that
/// could hold a sentence. Two closed vocabularies in series; the user's message
/// has no route through either.
public struct LocalActionSystemDiagnostics: ActionSystemDiagnosticSink {
    private let sink: any LocalInferenceDiagnosticSink

    public init(sink: any LocalInferenceDiagnosticSink) {
        self.sink = sink
    }

    public func record(_ event: ActionSystemDiagnosticEvent) {
        switch event {
        case .routerDecision(let decision, let category, let evidence):
            sink.info(
                .routerDecision,
                category: .generation,
                metadata: LocalInferenceMetadata()
                    .setting(.routerDecision, decision)
                    .setting(.actionCategory, category)
                    .setting(ifPresent: evidence, as: .routerEvidence)
                    // The router routes only on high-confidence evidence, so
                    // this is a constant rather than a measurement — recorded
                    // so the line says what kind of decision it was without the
                    // reader having to know the rule.
                    .setting(.routingConfidence, decision == "action" ? "high" : "none")
            )

        case .actionBackend(let backendID, let availability, let reason):
            sink.info(
                .actionBackend,
                category: .generation,
                metadata: LocalInferenceMetadata()
                    .setting(.actionBackendID, backendID)
                    .setting(.actionBackendAvailability, availability)
                    .setting(ifPresent: reason, as: .actionBackendReason)
            )

        case .semanticProcessingStarted(let backendID, let category):
            sink.info(
                .actionProcessingStarted,
                category: .generation,
                metadata: LocalInferenceMetadata()
                    .setting(.actionBackendID, backendID)
                    .setting(.actionCategory, category)
            )

        case .constrainedGeneration(let backendID, let active, let constraintType, let reason):
            sink.info(
                .actionConstrainedGeneration,
                category: .generation,
                metadata: LocalInferenceMetadata()
                    .setting(.actionBackendID, backendID)
                    .setting(.constrainedGenerationActive, active)
                    .setting(.constraintType, constraintType)
                    .setting(ifPresent: reason, as: .actionBackendReason)
            )

        case .semanticParse(let backendID, let success, let generatedIntent):
            sink.info(
                .semanticParse,
                category: .generation,
                metadata: LocalInferenceMetadata()
                    .setting(.actionBackendID, backendID)
                    .setting(.semanticParseSucceeded, success)
                    .setting(ifPresent: generatedIntent, as: .generatedIntent)
            )

        case .actionBackendFailure(let backendID, let reason):
            sink.problem(
                .actionBackendFailure,
                category: .generation,
                metadata: LocalInferenceMetadata()
                    .setting(.actionBackendID, backendID)
                    .setting(.actionBackendReason, reason)
            )
        }
    }
}

extension LocalInferenceMetadata {
    /// Sets a key only when there is something to set.
    ///
    /// Spelled with the value first so the call sites above read as one chain.
    /// An absent reason is absent from the line rather than an empty string:
    /// "" in a log is indistinguishable from a bug that dropped the value.
    fileprivate func setting(
        ifPresent value: String?, as key: LocalInferenceMetadataKey
    ) -> LocalInferenceMetadata {
        guard let value, !value.isEmpty else { return self }
        return setting(key, value)
    }
}
