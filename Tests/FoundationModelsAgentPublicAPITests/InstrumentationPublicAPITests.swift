import Foundation
import FoundationModels
import FoundationModelsAgent
import FoundationModelsAgentTestSupport
import Testing

@Generable
private struct PublicInstrumentationArguments: Sendable {
  let value: String
}

private struct PublicInstrumentationTool: Tool {
  let name = "public_instrumentation_tool"
  let description = "Returns the supplied value."

  @concurrent
  func call(arguments: PublicInstrumentationArguments) async throws -> String {
    arguments.value
  }
}

private struct PublicInstrumentationProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel
  let tool: PublicInstrumentationTool

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Use the public instrumentation tool.")
      tool
    }
    .model(model)
  }
}

private final class PublicInstrumentationCapture: AgentSessionInstrumentationSink,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storage: [AgentSessionInstrumentationEvent] = []

  func receive(_ event: AgentSessionInstrumentationEvent) {
    lock.withLock { storage.append(event) }
  }

  var events: [AgentSessionInstrumentationEvent] {
    lock.withLock { storage }
  }
}

private enum PublicInstrumentationSinkError: Error {
  case expected
}

private struct PublicFailingInstrumentationSink: AgentSessionInstrumentationSink {
  func receive(_ event: AgentSessionInstrumentationEvent) throws {
    throw PublicInstrumentationSinkError.expected
  }
}

@Suite("Instrumentation public API consumer")
struct InstrumentationPublicAPITests {
  @Test("Successful, failed, timed out, and cancelled runs settle truthfully")
  func terminalRunOutcomes() async throws {
    let successCapture = PublicInstrumentationCapture()
    let success = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "ok")]),
      instrumentation: .init(sink: successCapture)
    )
    #expect(try await success.respond(to: "Success").content == "ok")
    #expect(
      successCapture.events.contains {
        $0.kind == .run && $0.phase == .ended && $0.outcome == .succeeded
      })

    let failureCapture = PublicInstrumentationCapture()
    let failure = try AgentSession(
      model: RecordedLanguageModel(steps: [.failure("public failure")]),
      instrumentation: .init(sink: failureCapture)
    )
    await #expect(throws: RecordedLanguageModelError.self) {
      _ = try await failure.respond(to: "Fail")
    }
    #expect(
      failureCapture.events.contains {
        $0.kind == .run && $0.phase == .ended && $0.outcome == .failed
      })

    let timeoutCapture = PublicInstrumentationCapture()
    let timeout = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .delayedResponse(text: "late", delay: .seconds(1))
      ]),
      configuration: .init(responseTimeout: .milliseconds(5)),
      instrumentation: .init(sink: timeoutCapture)
    )
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await timeout.respond(to: "Timeout")
    }
    #expect(
      timeoutCapture.events.contains {
        $0.kind == .modelAttempt && $0.phase == .ended && $0.outcome == .failed
      })
    #expect(
      timeoutCapture.events.contains {
        $0.kind == .run && $0.phase == .ended && $0.outcome == .failed
      })

    let cancellationCapture = PublicInstrumentationCapture()
    let cancellation = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .delayedResponse(text: "late", delay: .seconds(1))
      ]),
      instrumentation: .init(sink: cancellationCapture)
    )
    let task = Task { try await cancellation.respond(to: "Cancel") }
    while !cancellationCapture.events.contains(where: {
      $0.kind == .modelAttempt && $0.phase == .began
    }) {
      await Task.yield()
    }
    task.cancel()
    await #expect(throws: (any Error).self) {
      _ = try await task.value
    }
    #expect(
      cancellationCapture.events.contains {
        $0.kind == .cancellation && $0.outcome == .cancelled
      })
    #expect(
      cancellationCapture.events.contains {
        $0.kind == .run && $0.phase == .ended && $0.outcome == .cancelled
      })
  }

  @Test("Streaming runs keep native partial delivery inside one correlated attempt")
  func streamingRun() async throws {
    let capture = PublicInstrumentationCapture()
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.responseFragments(["one", "two"])]),
      instrumentation: .init(sink: capture)
    )
    let partials = PublicLockedArray<String>()

    let response = try await session.respondStreaming(to: "Stream") { partial in
      partials.append(partial)
    }

    #expect(response.content == "onetwo")
    #expect(!partials.values.isEmpty)
    #expect(
      capture.events.filter {
        $0.kind == .modelAttempt && $0.phase == .began
      }.count == 1
    )
    #expect(
      capture.events.contains {
        $0.kind == .run && $0.phase == .ended && $0.outcome == .succeeded
      })
  }

  @Test("Explicit and dynamic-profile tools project policy and profile events")
  func toolAndProfileEvents() async throws {
    let explicitCapture = PublicInstrumentationCapture()
    let explicit = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(
          name: "public_instrumentation_tool",
          argumentsJSON: #"{"value":"explicit-secret"}"#
        ),
        .response(text: "done"),
      ]),
      tools: [PublicInstrumentationTool()],
      instrumentation: .init(sink: explicitCapture)
    )
    _ = try await explicit.respond(to: "Use the explicit tool")
    #expect(
      explicitCapture.events.contains {
        $0.kind == .governedToolCall && $0.phase == .ended && $0.outcome == .succeeded
      })
    #expect(
      explicitCapture.events.contains {
        $0.kind == .toolExecution && $0.phase == .ended && $0.outcome == .succeeded
      })
    #expect(
      explicitCapture.events.allSatisfy {
        !$0.attributes.values.contains("explicit-secret")
      })

    let profileCapture = PublicInstrumentationCapture()
    let profileTool = PublicInstrumentationTool()
    let registry = try DynamicProfileToolRegistry(tools: [profileTool])
    let governance = try DynamicProfileToolGovernanceConfiguration(trusting: registry)
    let profile = try AgentSession(
      checkpointCompatibilityID: "public-instrumentation-profile-v1",
      toolGovernance: governance,
      instrumentation: .init(sink: profileCapture)
    ) {
      PublicInstrumentationProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(
            name: "public_instrumentation_tool",
            argumentsJSON: #"{"value":"profile-secret"}"#
          ),
          .response(text: "done"),
        ]),
        tool: profileTool
      )
    }
    _ = try await profile.respond(to: "Use the profile tool")
    #expect(
      profileCapture.events.contains {
        $0.kind == .profileLifecycle && $0.phase == .began
      })
    #expect(
      profileCapture.events.contains {
        $0.kind == .profileTransition
          && $0.sourceEventKind == .profileToolAllowed
          && $0.outcome == .succeeded
      })
    #expect(
      profileCapture.events.contains {
        $0.kind == .profileLifecycle && $0.phase == .ended
      })
    #expect(
      profileCapture.events.allSatisfy {
        !$0.attributes.values.contains("profile-secret")
      })
  }

  @Test("Checkpoint restoration before a run becomes a correlated point event")
  func checkpointRestoreBeforeRun() async throws {
    let capture = PublicInstrumentationCapture()
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "restored")]),
      checkpointStore: InMemoryCheckpointStore(),
      instrumentation: .init(sink: capture)
    )

    try await session.prewarm()
    let response = try await session.respond(to: "Continue")

    #expect(
      capture.events.contains {
        $0.runID == response.run.id
          && $0.kind == .checkpointRestore
          && $0.phase == .event
          && $0.attributes["restored_before_run"] == "true"
      })
  }

  @Test("Routed context-budget runs project canonical routing and context phases")
  func routingAndContext() async throws {
    let capture = PublicInstrumentationCapture()
    let model = RecordedLanguageModel(steps: [.response(text: "routed")])
    let descriptor = FoundationModelsAgentRouteDescriptor(
      id: "public-route",
      purpose: "Exercise public instrumentation.",
      declaredCapabilities: [.guidedGeneration],
      availability: .init(state: .available),
      privacyClass: .onDevice,
      networkClass: .none,
      contextSize: .known(tokenLimit: 32),
      reasoningSupport: .unsupported,
      accountingProvenance: .none
    )
    let decision = FoundationModelsAgentRouteDecision(
      decidedAt: Date(timeIntervalSince1970: 1_800_000_000),
      requirements: .init(),
      plan: .init(primaryRouteID: descriptor.id),
      selectedRouteID: descriptor.id,
      selectedFallback: false,
      candidateDecisions: [
        .init(candidate: descriptor, outcome: .selected)
      ]
    )
    let session = try AgentSession(
      selection: FoundationModelsAgentRouteSelection(model: model, decision: decision),
      configuration: .init(
        contextBudget: .init(reservedResponseTokens: 1)
      ),
      contextMeasurer: AgentSessionContextMeasurer { _, _ in
        AgentSessionContextTokenCounts(
          contextSize: 32,
          instructions: 0,
          tools: 0,
          prompt: 2,
          schema: 0,
          transcript: 0
        )
      },
      instrumentation: .init(sink: capture)
    )

    #expect(try await session.respond(to: "Route").content == "routed")
    #expect(
      capture.events.contains {
        $0.kind == .routingDecision
          && $0.sourceEventKind == .routeSelected
          && $0.outcome == .succeeded
      })
    #expect(
      capture.events.contains {
        $0.kind == .contextBudget
          && $0.sourceEventKind == .contextBudgetEvaluated
          && $0.outcome == .succeeded
          && $0.attributes["before_total_input_tokens"] == "2"
      })
    #expect(capture.events.allSatisfy { $0.attributes["route_id"] == nil })
  }

  @Test("Canonical root and child lineage overrides reserved caller metadata")
  func canonicalLineageCorrelation() async throws {
    let capture = PublicInstrumentationCapture()
    let root = AgentRunLineage.root()
    let child = try root.descendant(taskID: AgentTaskID())
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "child")]),
      instrumentation: .init(
        correlationMetadata: [
          "request_id": "public-request",
          "root_run_id": "caller-must-not-override",
          "task_id": "caller-must-not-override",
        ],
        sink: capture
      )
    )

    let response = try await session.respond(to: "Child", lineage: child)

    #expect(response.run.lineage == child)
    #expect(
      capture.events.allSatisfy {
        $0.runID == child.runID.rawValue
          && $0.correlationMetadata["run_id"] == child.runID.description
          && $0.correlationMetadata["root_run_id"] == child.rootRunID.description
          && $0.correlationMetadata["parent_run_id"] == child.parentRunID?.description
          && $0.correlationMetadata["task_id"] == child.taskID?.description
          && $0.correlationMetadata["request_id"] == "public-request"
      })
  }

  @Test("Concurrent sessions keep independent canonical correlation")
  func concurrentSessions() async throws {
    let capture = PublicInstrumentationCapture()
    let root = AgentRunLineage.root()
    let firstLineage = try root.descendant(taskID: AgentTaskID())
    let secondLineage = try root.descendant(taskID: AgentTaskID())
    let first = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .delayedResponse(text: "one", delay: .milliseconds(10))
      ]),
      instrumentation: .init(sink: capture)
    )
    let second = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "two")]),
      instrumentation: .init(sink: capture)
    )

    async let firstResponse = first.respond(to: "First", lineage: firstLineage)
    async let secondResponse = second.respond(to: "Second", lineage: secondLineage)
    let responses = try await [firstResponse, secondResponse]

    #expect(
      Set(responses.map(\.run.id)) == [firstLineage.runID.rawValue, secondLineage.runID.rawValue])
    for lineage in [firstLineage, secondLineage] {
      let events = capture.events.filter { $0.runID == lineage.runID.rawValue }
      #expect(!events.isEmpty)
      #expect(
        events.allSatisfy {
          $0.correlationMetadata["root_run_id"] == root.runID.description
            && $0.correlationMetadata["task_id"] == lineage.taskID?.description
        })
    }
  }

  @Test("Redaction, disabled mode, no-op sinks, and sink failures are isolated")
  func privacyAndSinkBehavior() async throws {
    let redactedCapture = PublicInstrumentationCapture()
    let redacted = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .failure("api_key=public-super-secret")
      ]),
      instrumentation: .init(
        contentPolicy: .unsafeExplicitlyEnabled(maximumCharacters: 64),
        sink: redactedCapture
      )
    )
    await #expect(throws: RecordedLanguageModelError.self) {
      _ = try await redacted.respond(to: "PROMPT_MUST_NOT_APPEAR")
    }
    let diagnostics = redactedCapture.events.compactMap(\.diagnosticMessage).joined(separator: " ")
    #expect(!diagnostics.contains("public-super-secret"))
    #expect(!diagnostics.contains("PROMPT_MUST_NOT_APPEAR"))
    #expect(redactedCapture.events.allSatisfy { $0.diagnosticMessage?.count ?? 0 <= 64 })

    let disabledCapture = PublicInstrumentationCapture()
    let disabled = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "disabled")]),
      instrumentation: .init(isEnabled: false, sink: disabledCapture)
    )
    #expect(try await disabled.respond(to: "Disabled").content == "disabled")
    #expect(disabledCapture.events.isEmpty)

    let noOp = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "no-op")]),
      instrumentation: .init(sink: NoOpAgentSessionInstrumentationSink())
    )
    #expect(try await noOp.respond(to: "No-op").content == "no-op")

    let failing = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "isolated")]),
      instrumentation: .init(sink: PublicFailingInstrumentationSink())
    )
    #expect(try await failing.respond(to: "Sink failure").content == "isolated")
  }
}

private final class PublicLockedArray<Element>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Element] = []

  func append(_ value: Element) {
    lock.withLock { storage.append(value) }
  }

  var values: [Element] {
    lock.withLock { storage }
  }
}
