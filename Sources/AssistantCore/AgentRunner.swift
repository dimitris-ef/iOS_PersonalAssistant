import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantTools
import ExecutiveSupport
import Foundation

/// The multi-round loop: ask, validate, authorize, execute, show the results,
/// ask again.
///
/// ## Where this sits
///
/// Inside the application, between `AssistantEngine` and the tool layer — and
/// deliberately **not** inside any provider. A loop that lived in
/// `RemoteAIProvider` would be a loop that Apple's provider did not have, and
/// the day a local model arrives it would need a third. More importantly, a
/// provider that ran the loop would be a provider that executes tools, and the
/// entire safety argument of this codebase rests on it not being able to.
///
/// So the contract is unchanged from the single-round version: **the model
/// proposes, the application decides.** Every round is a fresh piece of
/// untrusted output. Nothing about having succeeded once grants a second call
/// any standing — round six is decoded, validated, authorized and permission
/// checked exactly as round one was.
///
/// ## The shape of a round
///
/// 1. Ask the provider, with everything that has happened so far.
/// 2. Decode and validate the calls. Rejects become results the model can read.
/// 3. If one of them is a question, stop: nothing else in that round runs.
/// 4. Claim each call in the ledger. Already done means reuse, never re-run.
/// 5. Order what is left so producers run before the calls that use them.
/// 6. Plan — which is where authorization happens and where the app's own
///    reminder support is added — and execute action by action.
/// 7. Feed the results back as tool messages and go round again, unless
///    something says stop.
///
/// ## What stops it
///
/// The model finishing, the round limit, the tool budget, repeated proposals of
/// something already done, a provider failure, a clarification, or the user
/// cancelling. All seven are recorded as an ``AgentStopReason``; none of them is
/// an infinite loop, and none of them discards work already done.
struct AgentRunner: Sendable {
    struct Outcome: Sendable {
        var text: String
        var plan: AssistantActionPlan
        var results: [ToolResult]
        var reminderPlans: [ReminderPlan]
        var providerID: AIProviderIdentifier
        var status: AgentTurnStatus
        var clarification: ClarificationRequest?
        var diagnostics: AgentDiagnostics
    }

    let repositories: AssistantRepositories
    let planner: any ActionPlanner
    let executor: any ToolExecutor
    let promptBuilder: SystemPromptBuilder
    let decoder: ToolRequestDecoder
    let dateProvider: any DateProvider
    let ledger: ToolExecutionLedger
    let limits: AgentLimits
    let summarizer: TurnSummarizer
    let logger: any AgentLogger
    let dependencies = ToolDependencyResolver()

    // MARK: The loop

    func run(
        provider: any AIProvider,
        context: AssistantContext,
        conversationID: Conversation.ID,
        turnID: UUID = UUID()
    ) async throws -> Outcome {
        let scope = "\(conversationID)/\(turnID)"

        var messages = promptBuilder.messages(for: context)
        var text = ""
        var actions: [AssistantAction] = []
        var rejected: [RejectedToolCall] = []
        var results: [ToolResult] = []
        var toolResults: [AIToolResult] = []
        var reminderPlans: [ReminderPlan] = []
        var rounds: [AgentRoundRecord] = []
        var providerID = provider.metadata.id
        var budget = limits.maximumToolCallsPerTurn
        var clarification: ClarificationRequest?
        var stopReason: AgentStopReason = .modelFinished
        var round = 0

        loop: while round < limits.maximumRounds {
            round += 1

            if Task.isCancelled {
                stopReason = .cancelled
                break loop
            }

            let request = AIRequest(
                model: context.settings.preferredModelID,
                systemPrompt: promptBuilder.systemPrompt(for: context),
                messages: messages,
                tools: promptBuilder.toolSchemas(),
                options: AIGenerationOptions(
                    maximumToolCalls: limits.maximumToolCallsPerRound,
                    maximumToolRounds: limits.maximumRounds
                )
            )

            let response: AIResponse
            do {
                response = try await provider.respond(to: request)
            } catch {
                // The first round is different in kind. Nothing has happened
                // yet, so there is no work to preserve and nothing truthful to
                // report — this is simply "the assistant could not answer", and
                // the caller shows it as an error. Every later round has
                // executed actions behind it, and throwing there would report a
                // failed turn for work that really happened.
                if round == 1 { throw error }
                stopReason = .providerFailed
                break loop
            }

            providerID = response.providerID
            if !response.text.isEmpty { text = response.text }

            guard !response.toolCalls.isEmpty else {
                stopReason = .modelFinished
                break loop
            }

            // The two budgets. Per round protects the round; per turn protects
            // against a model that proposes eight actions in each of six rounds.
            let allowance = min(limits.maximumToolCallsPerRound, budget)
            let calls = Array(response.toolCalls.prefix(allowance))
            let discarded = response.toolCalls.count - calls.count
            budget -= calls.count

            var record = AgentRoundRecord(
                round: round,
                providerID: providerID,
                proposedTools: calls.map(\.name),
                executedTools: [],
                statuses: [],
                failures: [],
                retries: 0,
                duplicatesDetected: 0,
                discardedCalls: discarded
            )

            var roundResults: [AIToolResult] = []

            // ---- Validation. Every round, no exceptions. ----
            let decoded = decoder.decode(
                calls.map { AIToolCallEnvelope(id: $0.id, name: $0.name, arguments: $0.arguments) }
            )
            rejected.append(contentsOf: decoded.rejected)
            for rejection in decoded.rejected {
                roundResults.append(
                    AIToolResult(
                        callID: rejection.callID,
                        toolName: rejection.name,
                        status: .failed,
                        failure: .validationFailure,
                        // Told to the model so it can correct itself. It still
                        // cannot bypass the rejection by trying again.
                        message: "Rejected. \(rejection.error.description)"
                    )
                )
            }

            // ---- A question ends the turn before anything else runs. ----
            if let ask = decoded.accepted.first(where: { $0.request.kind == .askClarification }) {
                if case .askClarification(let input) = ask.request {
                    clarification = ClarificationRequest(
                        question: input.question,
                        options: input.options ?? []
                    )
                }
                stopReason = .clarificationRequested

                for call in decoded.accepted where call.callID != ask.callID {
                    // Section 81, in one loop: when the assistant does not know
                    // which appointment was meant, it must not move one of them
                    // and then ask. Anything proposed alongside the question
                    // waits for the answer.
                    roundResults.append(
                        AIToolResult(
                            callID: call.callID,
                            toolName: call.request.kind.rawValue,
                            status: .skipped,
                            failure: .confirmationRequired,
                            message: "Not carried out: the assistant asked the user a question first."
                        )
                    )
                }

                toolResults.append(contentsOf: roundResults)
                record.statuses = roundResults.map(\.status)
                record.failures.append(contentsOf: roundResults.compactMap(\.failure))
                rounds.append(record)
                logger.record(turn: turnID, round: record)
                break loop
            }

            // ---- Duplicate suppression, before anything is planned. ----
            //
            // Before, not after: planning a duplicate would generate a second
            // reminder plan and a second set of support notifications for an
            // event that was created once, and those are side effects of their
            // own.
            var runnable: [ToolDependencyResolver.Node] = []
            var callSucceeded: [ToolCallID: Bool] = [:]
            var repetitionDetected = false

            for node in dependencies.resolve(decoded.accepted) {
                let fingerprint = ToolFingerprint(scope: scope, request: node.call.request)
                let claim = await ledger.claim(
                    callID: node.call.callID,
                    toolName: node.call.request.kind.rawValue,
                    fingerprint: fingerprint,
                    scope: scope,
                    now: dateProvider.now
                )

                switch claim {
                case .granted:
                    runnable.append(node)

                case .settled(let entry):
                    record.duplicatesDetected += 1
                    var reused = entry.result ?? AIToolResult(
                        callID: node.call.callID,
                        toolName: node.call.request.kind.rawValue,
                        status: .failed,
                        failure: .duplicate,
                        message: "This was already attempted in this turn."
                    )
                    reused.callID = node.call.callID
                    reused.wasAlreadyPerformed = true
                    roundResults.append(reused)
                    callSucceeded[node.call.callID] = reused.status.didAct

                    if await ledger.proposals(of: fingerprint) >= limits.repeatedProposalLimit {
                        repetitionDetected = true
                    }

                case .inFlight:
                    record.duplicatesDetected += 1
                    roundResults.append(
                        AIToolResult(
                            callID: node.call.callID,
                            toolName: node.call.request.kind.rawValue,
                            status: .skipped,
                            failure: .duplicate,
                            message: "The same action is already running; it was not started a second time."
                        )
                    )
                    callSucceeded[node.call.callID] = false
                }
            }

            // ---- Planning: authorization, and the app's own support. ----
            if !runnable.isEmpty {
                let planning = planner.makePlan(
                    from: ToolDecodingOutcome(accepted: runnable.map(\.call)),
                    context: context
                )

                // Saved before execution, exactly as the single-round version
                // did: the reminder plan is what the follow-up ladder reads, and
                // a crash between the two should leave support in place rather
                // than an action with nothing behind it.
                for reminderPlan in planning.reminderPlans {
                    try await repositories.reminderPlans.save(reminderPlan)
                }
                reminderPlans.append(contentsOf: planning.reminderPlans)
                actions.append(contentsOf: planning.plan.actions)

                let executed = await execute(
                    planning.plan,
                    nodes: runnable,
                    context: context,
                    callSucceeded: &callSucceeded,
                    record: &record
                )
                results.append(contentsOf: executed.results)
                roundResults.append(contentsOf: executed.toolResults)

                for node in runnable {
                    await ledger.finish(
                        callID: node.call.callID,
                        status: callSucceeded[node.call.callID] == true ? .succeeded : .failed,
                        result: executed.toolResults.first { $0.callID == node.call.callID }
                            ?? AIToolResult(
                                callID: node.call.callID,
                                toolName: node.call.request.kind.rawValue,
                                status: .failed,
                                failure: .temporaryFailure,
                                message: "No result was produced."
                            ),
                        now: dateProvider.now
                    )
                }
            }

            toolResults.append(contentsOf: roundResults)
            record.statuses = roundResults.map(\.status)
            record.failures.append(contentsOf: roundResults.compactMap(\.failure))
            rounds.append(record)
            logger.record(turn: turnID, round: record)

            if Task.isCancelled {
                stopReason = .cancelled
                break loop
            }

            if repetitionDetected {
                stopReason = .repeatedProposals
                break loop
            }

            // A provider that cannot be shown tool results gets exactly one
            // round. Asking it again would mean asking the same question with
            // no new information, and it would answer it the same way — with
            // the actions it has already taken.
            guard provider.metadata.supportsToolResultContinuation else {
                stopReason = .continuationUnsupported
                break loop
            }

            if budget <= 0 {
                stopReason = .toolBudgetExhausted
                break loop
            }

            if round >= limits.maximumRounds {
                stopReason = .agentRoundLimitExceeded
                break loop
            }

            // ---- What it asked for, then what actually happened. ----
            messages.append(AIMessage(role: .assistant, content: response.text, toolCalls: calls))
            for call in calls {
                let result = roundResults.first { $0.callID == call.id }
                    ?? AIToolResult(
                        callID: call.id,
                        toolName: call.name,
                        status: .failed,
                        failure: .providerFailure,
                        message: "No result was produced."
                    )
                messages.append(
                    AIMessage(
                        role: .tool,
                        content: result.renderedForModel,
                        toolCallID: call.id,
                        toolResult: result
                    )
                )
            }
        }

        if Task.isCancelled {
            stopReason = .cancelled
            await ledger.cancelUnfinished(scope: scope, now: dateProvider.now)
        }

        let status = Self.status(
            for: toolResults,
            stopReason: stopReason,
            clarification: clarification
        )

        let diagnostics = AgentDiagnostics(
            turnID: turnID,
            rounds: rounds,
            stopReason: stopReason,
            status: status
        )
        logger.finish(turn: turnID, diagnostics: diagnostics)

        return Outcome(
            text: reply(
                modelText: text,
                clarification: clarification,
                toolResults: toolResults,
                stopReason: stopReason
            ),
            plan: AssistantActionPlan(
                actions: actions,
                rejected: rejected,
                createdAt: dateProvider.now
            ),
            results: results,
            reminderPlans: reminderPlans,
            providerID: providerID,
            status: status,
            clarification: clarification,
            diagnostics: diagnostics
        )
    }

    // MARK: Execution

    private struct ExecutionOutcome {
        var results: [ToolResult] = []
        var toolResults: [AIToolResult] = []
    }

    /// Runs a round's plan one action at a time.
    ///
    /// One at a time rather than handing the whole plan to the executor, because
    /// three things here are per-action decisions: whether a dependency of it
    /// succeeded, whether its failure is worth one retry, and whether the user
    /// has cancelled since the last one. The executor's own contract is
    /// unchanged — it is still the only thing that performs a tool, and it still
    /// re-checks authorization and permission for every action it is given.
    private func execute(
        _ plan: AssistantActionPlan,
        nodes: [ToolDependencyResolver.Node],
        context: AssistantContext,
        callSucceeded: inout [ToolCallID: Bool],
        record: inout AgentRoundRecord
    ) async -> ExecutionOutcome {
        var outcome = ExecutionOutcome()
        let nodesByCall = Dictionary(uniqueKeysWithValues: nodes.map { ($0.call.callID, $0) })
        let supportCounts = Self.supportActionCounts(in: plan)

        // Support actions belong to whichever model call was planned before
        // them. Tracked so that support for a task that was never created is
        // not scheduled against a task id that does not exist.
        var parentCallID: ToolCallID?
        var parentKind: ToolKind?
        var parentActed = true

        for action in plan.actions {
            if let callID = action.sourceCallID {
                parentCallID = callID
                parentKind = action.kind
                parentActed = true
            }

            if Task.isCancelled {
                let result = ToolResult(
                    actionID: action.id,
                    kind: action.kind,
                    outcome: .failed(reason: "cancelled"),
                    message: "Not started: you stopped the assistant.",
                    producedAt: context.now,
                    failure: .cancelled
                )
                outcome.results.append(result)
                if let callID = action.sourceCallID {
                    callSucceeded[callID] = false
                    outcome.toolResults.append(
                        Self.toolResult(for: action, result: result, callID: callID, supportActions: 0)
                    )
                }
                continue
            }

            // A dependency of this call failed: run it and it acts on an
            // identifier that was never created.
            if let callID = action.sourceCallID,
               let node = nodesByCall[callID],
               let unmet = node.dependsOn.first(where: { callSucceeded[$0] != true }) {
                let result = ToolResult(
                    actionID: action.id,
                    kind: action.kind,
                    outcome: .failed(reason: "a dependency did not succeed"),
                    message: "Skipped: it needed \(nodesByCall[unmet]?.call.request.kind.rawValue ?? "an earlier action") to work first.",
                    producedAt: context.now,
                    failure: .dependencyFailed
                )
                outcome.results.append(result)
                callSucceeded[callID] = false
                parentActed = false
                outcome.toolResults.append(
                    Self.toolResult(for: action, result: result, callID: callID, supportActions: 0)
                )
                continue
            }

            // Support the app added for a model call that did not happen.
            //
            // Only skipped when the support genuinely depends on it. A task's
            // reminders point at a task id, so scheduling them for a task that
            // was never saved leaves the user with a Done button that does
            // nothing. A calendar event's reminders point at nothing but a
            // clock — and section 50 is explicit that they should still be set
            // when the calendar write is the thing that was refused, because the
            // time is already known.
            if action.sourceCallID == nil,
               parentCallID != nil,
               !parentActed,
               parentKind == .createTask {
                let result = ToolResult(
                    actionID: action.id,
                    kind: action.kind,
                    outcome: .failed(reason: "the task it supports was not created"),
                    message: "Skipped: the task it belongs to was not created.",
                    producedAt: context.now,
                    failure: .dependencyFailed
                )
                outcome.results.append(result)
                continue
            }

            var result = await perform(action, context: context)
            var attempt = 0
            while
                let failure = result.failure,
                failure.isAutomaticallyRetryable,
                attempt < limits.maximumToolRetries
            {
                // Bounded, and only for categories that can plausibly change
                // between two attempts a moment apart. A denied permission is
                // not one of them, and neither is an argument that failed
                // validation: retrying those means asking the same question
                // twice and, in the permission case, pestering someone about a
                // decision they have already made.
                attempt += 1
                record.retries += 1
                result = await perform(action, context: context)
            }

            outcome.results.append(result)

            if let callID = action.sourceCallID {
                let acted = result.outcome.didChangeAnything
                callSucceeded[callID] = acted
                parentActed = acted
                record.executedTools.append(action.kind.rawValue)
                outcome.toolResults.append(
                    Self.toolResult(
                        for: action,
                        result: result,
                        callID: callID,
                        supportActions: supportCounts[callID] ?? 0
                    )
                )
            }
        }

        return outcome
    }

    /// How many reminders the ``SupportPlanner`` added for each model call.
    ///
    /// Read off the plan's order: the planner emits a model call's action and
    /// then the support it generated for it, so a run of actions with no source
    /// call belongs to the last one that had one.
    static func supportActionCounts(in plan: AssistantActionPlan) -> [ToolCallID: Int] {
        var counts: [ToolCallID: Int] = [:]
        var current: ToolCallID?
        for action in plan.actions {
            if let callID = action.sourceCallID {
                current = callID
                counts[callID] = counts[callID] ?? 0
            } else if let callID = current {
                counts[callID, default: 0] += 1
            }
        }
        return counts
    }

    private func perform(_ action: AssistantAction, context: AssistantContext) async -> ToolResult {
        let single = AssistantActionPlan(actions: [action], createdAt: context.now)
        let results = await executor.execute(single, context: context)
        return results.first
            ?? ToolResult(
                actionID: action.id,
                kind: action.kind,
                outcome: .failed(reason: "the executor produced no result"),
                message: "Failed: \(action.request.summary)",
                producedAt: context.now,
                failure: .temporaryFailure
            )
    }

    // MARK: Shaping results

    /// One executed action as the model is shown it.
    static func toolResult(
        for action: AssistantAction,
        result: ToolResult,
        callID: ToolCallID,
        supportActions: Int
    ) -> AIToolResult {
        var payload = payload(for: action.request)
        if supportActions > 0 {
            // So the model knows the reminders exist and does not schedule its
            // own on top of the ones the SupportPlanner just made.
            payload["remindersAddedByApp"] = String(supportActions)
        }

        let status: AIToolStatus
        switch result.outcome {
        case .executed:
            status = .succeeded
        case .simulated(let platform):
            status = .simulated
            payload["recordedBy"] = platform
        case .awaitingConfirmation:
            status = .awaitingConfirmation
        case .denied, .failed, .unsupported:
            status = .failed
        }

        return AIToolResult(
            callID: callID,
            toolName: action.kind.rawValue,
            status: status,
            payload: payload,
            failure: result.failure,
            message: result.message
        )
    }

    /// The few normalized facts worth carrying back — identifiers and the
    /// handful of fields a next step might need.
    ///
    /// Not the platform object. A serialized `EKEvent` in every continuation
    /// round is how a six-round turn ends up with a prompt the size of a novel,
    /// and none of it would tell the model anything the identifier does not.
    static func payload(for request: ToolRequest) -> [String: String] {
        switch request {
        case .createCalendarEvent(let input):
            var values = ["title": input.title, "start": iso(input.start)]
            if let id = input.eventID { values["eventID"] = id.description }
            return values
        case .updateCalendarEvent(let input):
            return ["eventID": input.eventID.description]
        case .deleteCalendarEvent(let input):
            return ["eventID": input.eventID.description]
        case .createTask(let input):
            var values = ["title": input.title]
            if let id = input.taskID { values["taskID"] = id.description }
            return values
        case .completeTask(let input):
            return ["taskID": input.taskID.description]
        case .createFollowUp(let input):
            return ["taskID": input.taskID.description, "checkBackAt": iso(input.checkBackAt)]
        case .createReminder(let input):
            var values = ["title": input.title]
            if let due = input.dueDate { values["dueDate"] = iso(due) }
            return values
        case .completeReminder(let input):
            return ["reminderID": input.reminderID.description]
        case .createAlarm(let input):
            return ["label": input.label, "fireDate": iso(input.fireDate)]
        case .updateAlarm(let input):
            return ["alarmID": input.alarmID.description]
        case .cancelAlarm(let input):
            return ["alarmID": input.alarmID.description]
        case .scheduleNotification(let input):
            return ["title": input.title, "fireDate": iso(input.fireDate)]
        case .storeMemory(let input):
            // The kind, never the content. A memory is the most personal thing
            // this app holds; the model wrote it and does not need it read back.
            return ["kind": input.kind.rawValue]
        case .updateMemory(let input):
            return ["memoryID": input.memoryID.description]
        case .createRoutine(let input):
            var values = ["title": input.title, "frequency": input.recurrence.frequency]
            if let id = input.routineID { values["routineID"] = id.description }
            return values
        case .addTaskDependency(let input):
            return [
                "prerequisiteTaskID": input.prerequisiteTaskID.description,
                "dependentTaskID": input.dependentTaskID.description,
            ]
        case .startTask(let input):
            return ["taskID": input.taskID.description]
        case .getUpcomingSchedule, .askClarification:
            return [:]
        }
    }

    private static func iso(_ date: Date) -> String {
        SystemPromptBuilder.isoFormatter.string(from: date)
    }

    // MARK: Aggregation

    /// The turn's status, read off the results rather than off intent.
    static func status(
        for results: [AIToolResult],
        stopReason: AgentStopReason,
        clarification: ClarificationRequest?
    ) -> AgentTurnStatus {
        if stopReason == .cancelled { return .cancelled }
        if clarification != nil { return .requiresClarification }

        let acted = results.contains { $0.status.didAct }
        let pending = results.contains { $0.status == .awaitingConfirmation }
        let broken = results.contains { $0.status == .failed || $0.status == .skipped }

        if !broken && !pending {
            // Includes the ordinary case of a plain answer with no tools at all.
            return .success
        }
        if acted || pending { return .partialSuccess }
        return .failed
    }

    /// What the user is told.
    ///
    /// The single most important rule in this file: the model's own words are
    /// used **only** when the model saw the results before writing them. In
    /// every path where it did not — it never got a closing round, the provider
    /// failed, the loop hit its ceiling — the deterministic summary is used
    /// instead, because the model's last remark was written before the results
    /// existed and may be describing a success that did not happen.
    private func reply(
        modelText: String,
        clarification: ClarificationRequest?,
        toolResults: [AIToolResult],
        stopReason: AgentStopReason
    ) -> String {
        if let clarification {
            return clarification.prompt
        }

        switch stopReason {
        case .modelFinished:
            // It stopped asking for tools, so this text was written with the
            // results in front of it.
            if !modelText.isEmpty { return modelText }
            return summarizer.summary(for: toolResults, stopReason: stopReason)

        case .continuationUnsupported:
            // A provider that cannot read tool results never saw them either —
            // but it also proposed and described its actions in one breath, and
            // nothing else was executed after it spoke. Its text is as close to
            // the truth as this provider can get, so it stands as long as
            // nothing it asked for was refused.
            //
            // Validation rejections are not counted. A call the decoder threw
            // out never became an action, has no card under the reply, and is a
            // mistake in the model's own tool naming — telling the user about it
            // would be reporting our internals as their problem.
            let refused = toolResults.contains {
                $0.status == .failed && $0.failure != .validationFailure
            }
            if !modelText.isEmpty && !refused {
                return modelText
            }
            let summary = summarizer.summary(for: toolResults, stopReason: stopReason)
            return modelText.isEmpty ? summary : "\(modelText)\n\n\(summary)"

        case .providerFailed, .agentRoundLimitExceeded, .toolBudgetExhausted,
             .repeatedProposals, .cancelled, .clarificationRequested:
            return summarizer.summary(for: toolResults, stopReason: stopReason)
        }
    }
}
