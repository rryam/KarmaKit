import CoreAgent
import CoreAgentDeep
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

@Suite("CoreAgentDeep human-in-the-loop policy")
struct CoreAgentDeepHITLTests {
  @Test("Approve executes the original tool arguments")
  func approveExecutesOriginalArguments() async throws {
    let recorder = HITLProbeRecorder()
    let reviewer = RecordingHITLReviewer(decisions: [.approve])
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "hitl_probe", argumentsJSON: #"{"value":"original"}"#),
      .response(text: "approved"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [HITLProbeTool(recorder: recorder)],
      toolConfiguration: .init(
        interventionPolicy: CoreAgentDeepHITLPolicy(
          interruptOn: [
            "hitl_probe": .interrupt
          ],
          reviewer: reviewer
        )
      )
    )

    let response = try await session.respond(to: "Use the probe.")

    #expect(response.content == "approved")
    #expect(await recorder.values == ["original"])
    #expect(await reviewer.requests.map(\.toolRequest.manifest.name) == ["hitl_probe"])
    #expect(
      await reviewer.requests.first?.allowedDecisions
        == CoreAgentDeepHITLRule.defaultAllowedDecisions)
    #expect(response.run.events.contains { $0.kind == .toolInterventionApproved })
    #expect(response.run.events.contains { $0.kind == .toolExecutionCompleted })
    #expect(response.run.occursBefore(.toolInterventionApproved, .toolAuthorizationStarted))
    #expect(response.run.occursBefore(.toolAuthorizationSucceeded, .toolExecutionStarted))
  }

  @Test("Edit replaces the tool arguments before native decoding and execution")
  func editReplacesToolArguments() async throws {
    let recorder = HITLProbeRecorder()
    let reviewer = RecordingHITLReviewer(decisions: [
      .edit(arguments: GeneratedContent(HITLProbeArguments(value: "edited")))
    ])
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "hitl_probe", argumentsJSON: #"{"value":"original"}"#),
      .response(text: "edited"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [HITLProbeTool(recorder: recorder)],
      toolConfiguration: .init(
        interventionPolicy: CoreAgentDeepHITLPolicy(
          interruptOn: [
            "hitl_probe": .interrupt(allowedDecisions: [.approve, .edit])
          ],
          reviewer: reviewer
        )
      )
    )

    let response = try await session.respond(to: "Use the probe.")

    #expect(response.content == "edited")
    #expect(await recorder.values == ["edited"])
    #expect(
      response.run.events.contains { event in
        event.kind == .toolInterventionEdited
          && event.attributes["edited_arguments_digest"] != nil
          && event.attributes["arguments_source"] == "intervention_edit"
          && event.attributes["requested_arguments_json"]?.contains("original") == true
          && event.attributes["executed_arguments_json"]?.contains("edited") == true
      })
    let authorization = try #require(
      response.run.events.first { $0.kind == .toolAuthorizationSucceeded }
    )
    #expect(authorization.attributes["arguments_source"] == "intervention_edit")
    #expect(authorization.attributes["executed_arguments_digest"] != nil)
    let transcripts = model.recorder.capturedTranscripts()
    #expect(transcripts.count == 2)
    #expect(transcripts[1].containsText("edited"))
    #expect(!transcripts[1].containsText("original-result"))
  }

  @Test("Edited arguments are authorized before execution")
  func editedArgumentsAreAuthorizedBeforeExecution() async throws {
    let recorder = HITLProbeRecorder()
    let reviewer = RecordingHITLReviewer(decisions: [
      .edit(arguments: GeneratedContent(HITLProbeArguments(value: "blocked")))
    ])
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "hitl_probe", argumentsJSON: #"{"value":"original"}"#)
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [HITLProbeTool(recorder: recorder)],
      toolConfiguration: .init(
        policy: ArgumentValueDenyPolicy(disallowedValue: "blocked"),
        interventionPolicy: CoreAgentDeepHITLPolicy(
          interruptOn: [
            "hitl_probe": .interrupt(allowedDecisions: [.approve, .edit])
          ],
          reviewer: reviewer
        )
      )
    )

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use the probe.")
    }

    #expect(await recorder.values.isEmpty)
    let run = try #require(await session.lastRun())
    #expect(run.eventKinds.contains(.toolInterventionEdited))
    #expect(run.eventKinds.contains(.toolAuthorizationDenied))
    #expect(run.occursBefore(.toolInterventionEdited, .toolAuthorizationDenied))
    #expect(!run.eventKinds.contains(.toolExecutionStarted))
    #expect(
      run.events.first { $0.kind == .toolAuthorizationDenied }?
        .attributes["arguments_source"] == "intervention_edit"
    )
  }

  @Test("Per-call HITL policy rejects edited target allowlists at the args-only boundary")
  func perCallHITLPolicyRejectsEditedTargetAllowlistsAtArgsOnlyBoundary() async throws {
    let recorder = HITLProbeRecorder()
    let reviewer = RecordingHITLReviewer(decisions: [
      .edit(arguments: GeneratedContent(HITLProbeArguments(value: "edited")))
    ])
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "hitl_probe", argumentsJSON: #"{"value":"original"}"#)
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [HITLProbeTool(recorder: recorder)],
      toolConfiguration: .init(
        interventionPolicy: CoreAgentDeepHITLPolicy(
          interruptOn: [
            "hitl_probe": .interrupt(
              allowedDecisions: [.edit],
              allowedEditedActionNames: ["other_probe"]
            )
          ],
          reviewer: reviewer
        )
      )
    )

    var thrown: (any Error)?
    do {
      _ = try await session.respond(to: "Use the probe.")
      Issue.record("Expected edited target allowlist to fail at the args-only boundary.")
    } catch {
      thrown = error
    }
    let toolCallError = try #require(thrown as? LanguageModelSession.ToolCallError)
    #expect(
      toolCallError.underlyingError as? CoreAgentDeepHITLError
        == .editedToolNameUnsupportedForNativeAdapter(
          reviewed: "hitl_probe",
          edited: "other_probe"
        )
    )

    #expect(await reviewer.requests.isEmpty)
    #expect(await recorder.values.isEmpty)
    let run = try #require(await session.lastRun())
    #expect(run.eventKinds.contains(.toolInterventionFailed))
    #expect(!run.eventKinds.contains(.toolExecutionStarted))
  }

  @Test("Edited argument audit redacts sensitive JSON fields")
  func editedArgumentAuditRedactsSensitiveFields() async throws {
    let reviewer = RecordingHITLReviewer(decisions: [
      .edit(
        arguments: GeneratedContent(
          SecretProbeArguments(recipient: "edited@example.com", password: "open-sesame")
        )
      )
    ])
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        name: "secret_probe",
        argumentsJSON: #"{"recipient":"original@example.com","password":"original-secret"}"#
      ),
      .response(text: "redacted"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [SecretProbeTool()],
      toolConfiguration: .init(
        interventionPolicy: CoreAgentDeepHITLPolicy(
          interruptOn: ["secret_probe": .interrupt(allowedDecisions: [.edit])],
          reviewer: reviewer
        )
      )
    )

    let response = try await session.respond(to: "Use the secret probe.")

    let editEvent = try #require(
      response.run.events.first { $0.kind == .toolInterventionEdited }
    )
    let requestedJSON = try #require(editEvent.attributes["requested_arguments_json"])
    let executedJSON = try #require(editEvent.attributes["executed_arguments_json"])
    #expect(requestedJSON.contains("original@example.com"))
    #expect(executedJSON.contains("edited@example.com"))
    #expect(!requestedJSON.contains("original-secret"))
    #expect(!executedJSON.contains("open-sesame"))
    #expect(requestedJSON.contains("[REDACTED]"))
    #expect(executedJSON.contains("[REDACTED]"))
  }

  @Test("Reject skips tool execution and returns feedback as the tool result")
  func rejectSkipsExecutionAndReturnsFeedback() async throws {
    let recorder = HITLProbeRecorder()
    let reviewer = RecordingHITLReviewer(decisions: [
      .reject(reason: "Do not call this tool right now.")
    ])
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "hitl_probe", argumentsJSON: #"{"value":"side-effect"}"#),
      .response(text: "handled rejection"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [HITLProbeTool(recorder: recorder)],
      toolConfiguration: .init(
        interventionPolicy: CoreAgentDeepHITLPolicy(
          interruptOn: [
            "hitl_probe": .interrupt(allowedDecisions: [.approve, .reject])
          ],
          reviewer: reviewer
        )
      )
    )

    let response = try await session.respond(to: "Use the probe.")

    #expect(response.content == "handled rejection")
    #expect(await recorder.values.isEmpty)
    let rejection = try #require(
      response.run.events.first { $0.kind == .toolInterventionRejected }
    )
    #expect(!response.run.eventKinds.contains(.toolExecutionStarted))
    let nativeOutput = try #require(
      response.run.events.first { $0.kind == .nativeToolOutputRecorded }
    )
    #expect(nativeOutput.attributes["output_source"] == "intervention_reject")
    #expect(nativeOutput.attributes["tool_invocation_id"] == rejection.attributes["invocation_id"])
    let transcripts = model.recorder.capturedTranscripts()
    #expect(transcripts.count == 2)
    #expect(transcripts[1].containsText("Do not call this tool right now."))
  }

  @Test("Respond skips tool execution and returns a direct human response")
  func respondSkipsExecutionAndReturnsHumanResponse() async throws {
    let recorder = HITLProbeRecorder()
    let reviewer = RecordingHITLReviewer(decisions: [
      .respond(message: "Use the account ending in 1234.")
    ])
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "hitl_probe", argumentsJSON: #"{"value":"question"}"#),
      .response(text: "used human answer"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [HITLProbeTool(recorder: recorder)],
      toolConfiguration: .init(
        interventionPolicy: CoreAgentDeepHITLPolicy(
          interruptOn: [
            "hitl_probe": .interrupt(allowedDecisions: [.respond])
          ],
          reviewer: reviewer
        )
      )
    )

    let response = try await session.respond(to: "Use the probe.")

    #expect(response.content == "used human answer")
    #expect(await recorder.values.isEmpty)
    let responseEvent = try #require(
      response.run.events.first { $0.kind == .toolInterventionResponded }
    )
    #expect(!response.run.eventKinds.contains(.toolExecutionStarted))
    let nativeOutput = try #require(
      response.run.events.first { $0.kind == .nativeToolOutputRecorded }
    )
    #expect(nativeOutput.attributes["output_source"] == "intervention_respond")
    #expect(
      nativeOutput.attributes["tool_invocation_id"] == responseEvent.attributes["invocation_id"])
    let transcripts = model.recorder.capturedTranscripts()
    #expect(transcripts.count == 2)
    #expect(transcripts[1].containsText("Use the account ending in 1234."))
  }

  @Test("Disallowed reviewer decisions fail closed before execution")
  func disallowedDecisionFailsClosed() async throws {
    let recorder = HITLProbeRecorder()
    let reviewer = RecordingHITLReviewer(decisions: [
      .edit(arguments: GeneratedContent(HITLProbeArguments(value: "edited")))
    ])
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "hitl_probe", argumentsJSON: #"{"value":"original"}"#)
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [HITLProbeTool(recorder: recorder)],
      toolConfiguration: .init(
        interventionPolicy: CoreAgentDeepHITLPolicy(
          interruptOn: [
            "hitl_probe": .interrupt(allowedDecisions: [.approve, .reject])
          ],
          reviewer: reviewer
        )
      )
    )

    let error = await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use the probe.")
    }

    #expect(
      error.containsHITLError(
        .decisionNotAllowed(toolName: "hitl_probe", decision: .edit)
      )
    )
    #expect(await recorder.values.isEmpty)
    let run = try #require(await session.lastRun())
    #expect(run.events.contains { $0.kind == .toolInterventionFailed })
    #expect(!run.events.contains { $0.kind == .toolExecutionStarted })
  }

  @Test("Predicate is evaluated once per governed tool call")
  func predicateIsEvaluatedOnce() async throws {
    let recorder = HITLProbeRecorder()
    let predicate = TogglingPredicate()
    let reviewer = RecordingHITLReviewer(decisions: [
      .reject(reason: "blocked by first predicate result")
    ])
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "hitl_probe", argumentsJSON: #"{"value":"toggle"}"#),
      .response(text: "handled toggle"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [HITLProbeTool(recorder: recorder)],
      toolConfiguration: .init(
        interventionPolicy: CoreAgentDeepHITLPolicy(
          interruptOn: [
            "hitl_probe": .interrupt(
              allowedDecisions: [.approve, .reject],
              when: { predicate.shouldInterrupt($0) }
            )
          ],
          reviewer: reviewer
        )
      )
    )

    let response = try await session.respond(to: "Use the probe.")

    #expect(response.content == "handled toggle")
    #expect(await recorder.values.isEmpty)
    #expect(predicate.count == 1)
    #expect(await reviewer.requests.count == 1)
    #expect(response.run.eventKinds.contains(.toolInterventionRejected))
  }

  @Test("Precheck failures do not record intervention outcome events")
  func precheckFailureDoesNotRecordInterventionOutcome() async throws {
    let recorder = HITLProbeRecorder()
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "hitl_probe", argumentsJSON: #"{"value":"precheck"}"#)
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [HITLProbeTool(recorder: recorder)],
      toolConfiguration: .init(
        interventionPolicy: PrecheckFailingInterventionPolicy()
      )
    )

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use the probe.")
    }

    #expect(await recorder.values.isEmpty)
    let run = try #require(await session.lastRun())
    #expect(!run.eventKinds.contains(.toolInterventionStarted))
    #expect(!run.eventKinds.contains(.toolInterventionFailed))
    #expect(!run.eventKinds.contains(.toolInterventionCancelled))
    #expect(!run.eventKinds.contains(.toolExecutionStarted))
  }

  @Test("Conditional interrupt predicates can bypass reviewer review")
  func conditionalPredicateBypassesReviewer() async throws {
    let recorder = HITLProbeRecorder()
    let reviewer = RecordingHITLReviewer(decisions: [
      .reject(reason: "should not be consulted")
    ])
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "hitl_probe", argumentsJSON: #"{"value":"safe"}"#),
      .response(text: "allowed"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [HITLProbeTool(recorder: recorder)],
      toolConfiguration: .init(
        interventionPolicy: CoreAgentDeepHITLPolicy(
          interruptOn: [
            "hitl_probe": .interrupt(
              allowedDecisions: [.approve, .reject],
              when: { request in request.argumentsJSON.contains(#""dangerous":true"#) }
            )
          ],
          reviewer: reviewer
        )
      )
    )

    let response = try await session.respond(to: "Use the probe.")

    #expect(response.content == "allowed")
    #expect(await recorder.values == ["safe"])
    #expect(await reviewer.requests.isEmpty)
    #expect(!response.run.events.contains { $0.kind == .toolInterventionStarted })
  }

  @Test("Direct decisions honor conditional interrupt predicates")
  func directDecisionHonorsConditionalPredicate() async throws {
    let reviewer = RecordingHITLReviewer(decisions: [
      .reject(reason: "should not be consulted")
    ])
    let policy = CoreAgentDeepHITLPolicy(
      interruptOn: [
        "hitl_probe": .interrupt(
          allowedDecisions: [.approve, .reject],
          when: { request in request.argumentsJSON.contains(#""dangerous":true"#) }
        )
      ],
      reviewer: reviewer
    )
    let request = CoreAgentToolRequest(
      runID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      invocationID: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
      manifest: CoreAgentToolManifest(
        name: "hitl_probe",
        description: "Records and returns the supplied value.",
        schemaJSON: "{}"
      ),
      arguments: GeneratedContent(HITLProbeArguments(value: "safe"))
    )

    let decision = try await policy.decide(request)

    if case .approve = decision {
      #expect(await reviewer.requests.isEmpty)
    } else {
      Issue.record("Expected direct decision to approve without reviewer when predicate is false.")
    }
  }
}

@Generable
private struct HITLProbeArguments: Sendable {
  let value: String
}

private actor HITLProbeRecorder {
  private(set) var values: [String] = []

  func record(_ value: String) {
    values.append(value)
  }
}

private struct HITLProbeTool: Tool {
  let recorder: HITLProbeRecorder
  let name = "hitl_probe"
  let description = "Records and returns the supplied value."

  @concurrent
  func call(arguments: HITLProbeArguments) async throws -> String {
    await recorder.record(arguments.value)
    return "\(arguments.value)-result"
  }
}

@Generable
private struct SecretProbeArguments: Sendable {
  let recipient: String
  let password: String
}

private struct SecretProbeTool: Tool {
  let name = "secret_probe"
  let description = "Returns the supplied recipient."

  @concurrent
  func call(arguments: SecretProbeArguments) async throws -> String {
    arguments.recipient
  }
}

private struct ArgumentValueDenyPolicy: CoreAgentToolPolicy {
  let disallowedValue: String

  func authorize(_ request: CoreAgentToolRequest) async throws {
    if request.argumentsJSON.contains(disallowedValue) {
      throw CoreAgentPolicyError.denied(
        toolName: request.manifest.name,
        reason: "Edited argument value is disallowed."
      )
    }
  }
}

private actor RecordingHITLReviewer: CoreAgentDeepHITLReviewer {
  private var decisions: [CoreAgentDeepHITLDecision]
  private(set) var requests: [CoreAgentDeepHITLReviewRequest] = []

  init(decisions: [CoreAgentDeepHITLDecision]) {
    self.decisions = decisions
  }

  func decide(_ request: CoreAgentDeepHITLReviewRequest) async throws
    -> CoreAgentDeepHITLDecision
  {
    requests.append(request)
    guard !decisions.isEmpty else {
      throw HITLReviewerError.exhausted
    }
    return decisions.removeFirst()
  }
}

private enum HITLReviewerError: Error {
  case exhausted
}

private final class TogglingPredicate: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int {
    lock.withLock { value }
  }

  func shouldInterrupt(_ request: CoreAgentToolRequest) -> Bool {
    lock.withLock {
      value += 1
      return value == 1
    }
  }
}

private enum PrecheckError: Error {
  case unavailable
}

private struct PrecheckFailingInterventionPolicy: CoreAgentToolInterventionPolicy {
  func shouldIntervene(_ request: CoreAgentToolRequest) async throws -> Bool {
    throw PrecheckError.unavailable
  }

  func decide(_ request: CoreAgentToolRequest) async throws -> CoreAgentToolInterventionDecision {
    Issue.record("Precheck failure should prevent decide from being called.")
    return .approve
  }
}

extension CoreAgentRun {
  fileprivate var eventKinds: [CoreAgentEventKind] {
    events.map(\.kind)
  }

  fileprivate func occursBefore(_ earlier: CoreAgentEventKind, _ later: CoreAgentEventKind) -> Bool
  {
    guard let earlierIndex = eventKinds.firstIndex(of: earlier),
      let laterIndex = eventKinds.firstIndex(of: later)
    else {
      return false
    }
    return earlierIndex < laterIndex
  }
}

extension Optional where Wrapped == any Error {
  fileprivate func containsHITLError(_ expected: CoreAgentDeepHITLError) -> Bool {
    guard let self else { return false }
    return self.containsHITLError(expected)
  }
}

extension Error {
  fileprivate func containsHITLError(_ expected: CoreAgentDeepHITLError) -> Bool {
    if let error = self as? CoreAgentDeepHITLError {
      return error == expected
    }
    return Mirror(reflecting: self).children.contains { child in
      guard let nested = child.value as? any Error else { return false }
      return nested.containsHITLError(expected)
    }
  }
}

extension Transcript {
  fileprivate func containsText(_ expected: String) -> Bool {
    contains { entry in
      switch entry {
      case .instructions(let instructions):
        instructions.segments.containsText(expected)
      case .prompt(let prompt):
        prompt.segments.containsText(expected)
      case .toolOutput(let output):
        output.segments.containsText(expected)
      case .response(let response):
        response.segments.containsText(expected)
      case .reasoning(let reasoning):
        reasoning.segments.containsText(expected)
      case .toolCalls(let calls):
        calls.contains { $0.arguments.jsonString.contains(expected) }
      @unknown default:
        false
      }
    }
  }
}

extension [Transcript.Segment] {
  fileprivate func containsText(_ expected: String) -> Bool {
    contains { segment in
      if case .text(let text) = segment {
        return text.content.contains(expected)
      }
      return false
    }
  }
}
