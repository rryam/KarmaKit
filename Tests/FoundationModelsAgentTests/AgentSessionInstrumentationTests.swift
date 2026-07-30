import Foundation
import FoundationModels
import FoundationModelsAgent
import FoundationModelsAgentTestSupport
import Testing

@Generable
private struct InstrumentationEchoArguments: Sendable {
  let value: String
}

private struct InstrumentationEchoTool: Tool {
  let name = "instrumentation_echo"
  let description = "Returns the supplied value."

  @concurrent
  func call(arguments: InstrumentationEchoArguments) async throws -> String {
    arguments.value
  }
}

private struct InstrumentationDynamicProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel
  let tool: InstrumentationEchoTool

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Use the instrumentation echo tool.")
      tool
    }
    .model(model)
  }
}

private final class InstrumentationEventCapture: AgentSessionInstrumentationSink,
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

private enum InstrumentationSinkFailure: Error {
  case intentional
}

private struct FailingInstrumentationSink: AgentSessionInstrumentationSink {
  func receive(_ event: AgentSessionInstrumentationEvent) throws {
    throw InstrumentationSinkFailure.intentional
  }
}

private actor InstrumentationAuthorizationSignal {
  private(set) var started = false

  func markStarted() {
    started = true
  }
}

@Suite("AgentSession Instruments correlation")
struct AgentSessionInstrumentationTests {
  @Test("Projects nested run, attempt, approval, tool, and checkpoint spans")
  func nestedSpans() async throws {
    let capture = InstrumentationEventCapture()
    let store = InMemoryCheckpointStore()
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(
          name: "instrumentation_echo",
          argumentsJSON: #"{"value":"approved"}"#
        ),
        .response(text: "done"),
      ]),
      tools: [InstrumentationEchoTool()],
      toolConfiguration: .init(
        policy: ApprovalRequiredToolPolicy(
          provider: ClosureFoundationModelsAgentApprovalProvider { _ in .approve }
        )
      ),
      checkpointStore: store,
      instrumentation: .init(
        correlationMetadata: [
          "root_id": UUID().uuidString,
          "parent_id": UUID().uuidString,
          "task_id": "tool-task",
        ],
        sink: capture
      )
    )

    let response = try await session.respond(to: "PROMPT_MUST_NOT_BE_LOGGED")
    let events = capture.events
    let runID = response.run.id
    #expect(!events.isEmpty)
    #expect(events.allSatisfy { $0.runID == runID })
    #expect(events.map(\.sequence) == Array(events.indices))
    #expect(events.allSatisfy { $0.diagnosticMessage == nil })
    #expect(events.allSatisfy { !$0.attributes.values.contains("approved") })

    let run = try #require(events.first { $0.kind == .run && $0.phase == .began })
    let attempt = try #require(
      events.first { $0.kind == .modelAttempt && $0.phase == .began })
    let tool = try #require(
      events.first { $0.kind == .governedToolCall && $0.phase == .began })
    let approval = try #require(
      events.first { $0.kind == .approvalWait && $0.phase == .began })
    let execution = try #require(
      events.first { $0.kind == .toolExecution && $0.phase == .began })

    #expect(attempt.parentSpanID == run.spanID)
    #expect(tool.parentSpanID == attempt.spanID)
    #expect(approval.parentSpanID == tool.spanID)
    #expect(execution.parentSpanID == tool.spanID)
    #expect(
      events.contains {
        $0.kind == .checkpointRestore && $0.phase == .ended && $0.outcome == .succeeded
      })
    #expect(
      events.contains {
        $0.kind == .checkpointWrite && $0.phase == .ended && $0.outcome == .succeeded
      })
    #expect(
      events.contains {
        $0.spanID == run.spanID && $0.phase == .ended && $0.outcome == .succeeded
      })
  }

  @Test("Emits retry ordering and bounds explicitly enabled diagnostics")
  func retryAndRedaction() async throws {
    let capture = InstrumentationEventCapture()
    let retry = try FoundationModelsAgentRetryPolicy(maximumAttempts: 2) { _ in true }
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .failure("api_key=super-secret-value"),
        .response(text: "MODEL_OUTPUT_MUST_NOT_BE_LOGGED"),
      ]),
      configuration: .init(retryPolicy: retry),
      instrumentation: .init(
        contentPolicy: .unsafeExplicitlyEnabled(maximumCharacters: 48),
        sink: capture
      )
    )

    _ = try await session.respond(to: "PROMPT_MUST_NOT_BE_LOGGED")

    let events = capture.events
    let retryIndex = try #require(events.firstIndex { $0.kind == .retry })
    let attempts = events.enumerated().filter {
      $0.element.kind == .modelAttempt && $0.element.phase == .began
    }
    #expect(attempts.count == 2)
    #expect(attempts[0].offset < retryIndex)
    #expect(retryIndex < attempts[1].offset)
    #expect(events.compactMap(\.diagnosticMessage).allSatisfy { $0.count <= 48 })
    let diagnostics = events.compactMap(\.diagnosticMessage).joined(separator: " ")
    #expect(!diagnostics.contains("super-secret-value"))
    #expect(!diagnostics.contains("PROMPT_MUST_NOT_BE_LOGGED"))
    #expect(!diagnostics.contains("MODEL_OUTPUT_MUST_NOT_BE_LOGGED"))
  }

  @Test("Correlates a checkpoint restored before the response run")
  func preloadedCheckpointRestore() async throws {
    let capture = InstrumentationEventCapture()
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "ready")]),
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
          && $0.outcome == .succeeded
          && $0.attributes["restored_before_run"] == "true"
      })
  }

  @Test("Ends approval and governed-tool spans as denied")
  func approvalDenial() async throws {
    let capture = InstrumentationEventCapture()
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(
          name: "instrumentation_echo",
          argumentsJSON: #"{"value":"blocked"}"#
        )
      ]),
      tools: [InstrumentationEchoTool()],
      toolConfiguration: .init(
        policy: ApprovalRequiredToolPolicy(
          provider: ClosureFoundationModelsAgentApprovalProvider { _ in
            .deny(reason: "No")
          }
        )
      ),
      instrumentation: .init(sink: capture)
    )

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Deny")
    }

    #expect(
      capture.events.contains {
        $0.kind == .approvalWait && $0.phase == .ended && $0.outcome == .denied
      })
    #expect(
      capture.events.contains {
        $0.kind == .governedToolCall && $0.phase == .ended && $0.outcome == .denied
      })
  }

  @Test("Cancellation closes nested spans and emits a cancellation seam")
  func cancellation() async throws {
    let capture = InstrumentationEventCapture()
    let signal = InstrumentationAuthorizationSignal()
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(
          name: "instrumentation_echo",
          argumentsJSON: #"{"value":"cancelled"}"#
        )
      ]),
      tools: [InstrumentationEchoTool()],
      toolConfiguration: .init(
        policy: ApprovalRequiredToolPolicy(
          provider: ClosureFoundationModelsAgentApprovalProvider { _ in
            await signal.markStarted()
            try await Task.sleep(for: .seconds(1))
            return .approve
          }
        )
      ),
      instrumentation: .init(sink: capture)
    )
    let task = Task { try await session.respond(to: "Cancel") }
    while !(await signal.started) {
      await Task.yield()
    }

    task.cancel()
    await #expect(throws: (any Error).self) {
      _ = try await task.value
    }

    #expect(
      capture.events.contains {
        $0.kind == .cancellation && $0.phase == .event && $0.outcome == .cancelled
      })
    #expect(
      capture.events.contains {
        $0.kind == .run && $0.phase == .ended && $0.outcome == .cancelled
      })
    #expect(
      capture.events.contains {
        $0.kind == .modelAttempt && $0.phase == .ended && $0.outcome == .cancelled
      })
  }

  @Test("Concurrent independent sessions retain separate run and task correlation")
  func independentSessions() async throws {
    let capture = InstrumentationEventCapture()
    let first = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .delayedResponse(text: "one", delay: .milliseconds(10))
      ]),
      instrumentation: .init(
        correlationMetadata: ["task_id": "one"],
        sink: capture
      )
    )
    let second = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "two")]),
      instrumentation: .init(
        correlationMetadata: ["task_id": "two"],
        sink: capture
      )
    )

    async let firstResponse = first.respond(to: "First")
    async let secondResponse = second.respond(to: "Second")
    let responses = try await [firstResponse, secondResponse]
    let runIDs = Set(responses.map(\.run.id))
    #expect(runIDs.count == 2)

    let events = capture.events.filter { runIDs.contains($0.runID) }
    #expect(Set(events.map { $0.correlationMetadata["task_id"] ?? "" }) == ["one", "two"])
    for runID in runIDs {
      let runEvents = events.filter { $0.runID == runID }
      #expect(runEvents.first?.kind == .run)
      #expect(runEvents.last?.kind == .run)
      #expect(runEvents.last?.outcome == .succeeded)
    }
  }

  @Test("A throwing sink cannot fail a model response")
  func sinkFailureIsolation() async throws {
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "unaffected")]),
      instrumentation: .init(sink: FailingInstrumentationSink())
    )

    #expect(try await session.respond(to: "Continue").content == "unaffected")
  }

  @Test("Dynamic profiles project lifecycle and native tool transitions")
  func profileLifecycle() async throws {
    let capture = InstrumentationEventCapture()
    let session = try AgentSession(
      checkpointCompatibilityID: "instrumentation-profile-v1",
      instrumentation: .init(sink: capture)
    ) {
      InstrumentationDynamicProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(
            name: "instrumentation_echo",
            argumentsJSON: #"{"value":"profile"}"#
          ),
          .response(text: "done"),
        ]),
        tool: InstrumentationEchoTool()
      )
    }

    _ = try await session.respond(to: "Use the tool")

    #expect(
      capture.events.contains {
        $0.kind == .profileLifecycle && $0.phase == .began
      })
    #expect(
      capture.events.contains {
        $0.kind == .profileTransition && $0.phase == .event
      })
    #expect(
      capture.events.contains {
        $0.kind == .profileLifecycle && $0.phase == .ended && $0.outcome == .succeeded
      })
  }
}
