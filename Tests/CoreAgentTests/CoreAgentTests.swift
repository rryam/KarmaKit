import CoreAgent
import CoreAgentTestSupport
import CoreGraphics
import Foundation
import FoundationModels
import Testing

@Generable
struct TestAnswer: Sendable {
  let value: String
}

@Generable
struct EchoArguments: Sendable {
  let value: String
}

actor InvocationCounter {
  private(set) var count = 0
  private(set) var values: [String] = []

  func record(_ value: String) {
    count += 1
    values.append(value)
  }
}

struct EchoTool: Tool {
  let counter: InvocationCounter
  let name = "echo"
  let description = "Returns the supplied value."

  @concurrent
  func call(arguments: EchoArguments) async throws -> String {
    await counter.record(arguments.value)
    return arguments.value
  }
}

struct SlowEchoTool: Tool {
  let name = "slow_echo"
  let description = "Returns the supplied value after a delay."

  @concurrent
  func call(arguments: EchoArguments) async throws -> String {
    try await Task.sleep(for: .seconds(1))
    return arguments.value
  }
}

struct SchemaHiddenEchoTool: Tool {
  let name = "schema_hidden_echo"
  let description = "Keeps its argument schema out of instructions."
  let includesSchemaInInstructions = false

  @concurrent
  func call(arguments: EchoArguments) async throws -> String {
    arguments.value
  }
}

struct TestDynamicProfile: LanguageModelSession.DynamicProfile {
  let instructions: String

  init(instructions: String = "Dynamic profile instructions.") {
    self.instructions = instructions
  }

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions(instructions)
    }
    .model(SystemLanguageModel.default)
  }
}

struct TestToolDynamicProfile: LanguageModelSession.DynamicProfile {
  let tool: EchoTool

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Use the echo tool.")
      tool
    }
    .model(SystemLanguageModel.default)
  }
}

enum ProfileLifecycleError: Error {
  case intentional
}

struct ThrowingLifecycleDynamicProfile: LanguageModelSession.DynamicProfile {
  let tool: EchoTool

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Use the echo tool.")
      tool
    }
    .model(SystemLanguageModel.default)
    .onToolOutput { _, _ in
      throw ProfileLifecycleError.intentional
    }
  }
}

final class NonSendableProfileState {
  let instructions: String

  init(instructions: String) {
    self.instructions = instructions
  }
}

struct NonSendableStateProfile: LanguageModelSession.DynamicProfile {
  let state: NonSendableProfileState

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions(state.instructions)
    }
    .model(SystemLanguageModel.default)
  }
}

final class ProfileFactoryCounter: @unchecked Sendable {
  let lock = NSLock()
  private var value = 0

  func increment() {
    lock.withLock { value += 1 }
  }

  var count: Int {
    lock.withLock { value }
  }
}

struct TestCustomSegment: Transcript.CustomSegment {
  struct Content: Codable, Equatable, Sendable {
    let value: String
  }

  let id: String
  let content: Content
}

actor RequestCapture {
  private(set) var requests: [CoreAgentToolRequest] = []

  func append(_ request: CoreAgentToolRequest) {
    requests.append(request)
  }
}

actor EventCapture {
  private(set) var events: [CoreAgentEvent] = []

  func append(_ event: CoreAgentEvent) {
    events.append(event)
  }
}

actor PartialCount {
  private(set) var value = 0

  func increment() {
    value += 1
  }
}

actor AuthorizationSignal {
  private(set) var started = false

  func markStarted() {
    started = true
  }
}

enum AuthorizationServiceError: Error {
  case unavailable
}

struct FailingAuthorizationPolicy: CoreAgentToolPolicy {
  func authorize(_ request: CoreAgentToolRequest) async throws {
    throw AuthorizationServiceError.unavailable
  }
}

enum RetentionError: Error {
  case shouldNotRunAutomatically
}

actor ObserverGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let current = waiters
    waiters.removeAll()
    for waiter in current {
      waiter.resume()
    }
  }
}

actor BooleanCapture {
  private(set) var values: [Bool] = []

  func append(_ value: Bool) {
    values.append(value)
  }
}

actor SessionReference {
  private var session: CoreAgentSession?

  func set(_ session: CoreAgentSession) {
    self.session = session
  }

  func get() -> CoreAgentSession? {
    session
  }
}

enum FailingCheckpointError: Error {
  case intentional
}

actor FailingCheckpointStore: CoreAgentCheckpointStore {
  func loadCheckpoint(for key: String) throws -> CoreAgentCheckpoint? {
    nil
  }

  func saveCheckpoint(_ checkpoint: CoreAgentCheckpoint, for key: String) throws {
    throw FailingCheckpointError.intentional
  }

  func removeCheckpoint(for key: String) throws {}
}

@Suite("CoreAgent native Foundation Models runtime")
struct CoreAgentTests {
  @Test("Uses native instructions, responses, usage, and receipts")
  func nativeTextResponse() async throws {
    let model = RecordedLanguageModel(
      steps: [.response(text: "hello", inputTokens: 4, outputTokens: 2)]
    )
    let session = try CoreAgentSession(
      model: model,
      instructions: Instructions("Always be concise.")
    )

    let response = try await session.respond(to: "Say hello")

    #expect(response.content == "hello")
    #expect(response.usage.inputTokens == 4)
    #expect(response.usage.outputTokens == 2)
    #expect(response.run.events.first?.kind == .runStarted)
    #expect(response.run.events.last?.kind == .runCompleted)
    #expect(try CoreAgentRunReceipt(run: response.run).verify())

    let captured = model.recorder.capturedTranscripts()
    #expect(captured.count == 1)
    #expect(
      captured[0].contains { entry in
        if case .instructions = entry { return true }
        return false
      })
    #expect(
      captured[0].contains { entry in
        if case .prompt = entry { return true }
        return false
      })
  }

  @Test("Preserves native structured generation")
  func structuredResponse() async throws {
    let model = RecordedLanguageModel(steps: [.response(text: #"{"value":"typed"}"#)])
    let session = try CoreAgentSession(model: model)

    let response = try await session.respond(to: "Return a value", generating: TestAnswer.self)

    #expect(response.content.value == "typed")
    #expect(response.rawContent.jsonString.contains("typed"))
  }

  @Test("Argument audit digests canonical JSON object shape")
  func argumentAuditDigestCanonicalizesJSONObjects() throws {
    let first = try GeneratedContent(json: #"{"b":2,"a":{"token":"same","x":1}}"#)
    let second = try GeneratedContent(
      json: #"{ "a": { "x": 1, "token": "same" }, "b": 2 }"#
    )

    #expect(CoreAgentArgumentAudit.digest(first) == CoreAgentArgumentAudit.digest(second))
    #expect(CoreAgentArgumentAudit.digest(first) == CoreAgentArgumentAudit.digest(first))
  }

  @Test("Authorizes native tool arguments and executes the tool once")
  func governedToolRoundTrip() async throws {
    let counter = InvocationCounter()
    let capture = RequestCapture()
    let approval = ClosureCoreAgentApprovalProvider { request in
      await capture.append(request)
      return .approve
    }
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"approved"}"#),
      .response(text: "done"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [EchoTool(counter: counter)],
      toolConfiguration: .init(
        policy: ApprovalRequiredToolPolicy(provider: approval),
        maximumCallsPerRun: 1
      )
    )

    let response = try await session.respond(to: "Use echo")

    #expect(response.content == "done")
    #expect(await counter.count == 1)
    #expect(await counter.values == ["approved"])
    #expect(await capture.requests.count == 1)
    #expect(await capture.requests.first?.argumentsJSON.contains("approved") == true)
    #expect(response.run.events.contains { $0.kind == .toolAuthorizationSucceeded })
    #expect(response.run.events.contains { $0.kind == .nativeToolCallRecorded })
    #expect(response.run.events.contains { $0.kind == .nativeToolOutputRecorded })
  }

  @Test("A denied tool never reaches its implementation")
  func deniedToolDoesNotExecute() async throws {
    let counter = InvocationCounter()
    let eventCapture = EventCapture()
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"blocked"}"#)
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [EchoTool(counter: counter)],
      toolConfiguration: .init(
        policy: ApprovalRequiredToolPolicy(
          provider: ClosureCoreAgentApprovalProvider { _ in .deny(reason: "User declined") }
        )
      ),
      observers: [ClosureCoreAgentObserver { await eventCapture.append($0) }]
    )

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo")
    }

    await session.flushObservers()
    #expect(await counter.count == 0)
    #expect(await eventCapture.events.contains { $0.kind == .toolAuthorizationDenied })
  }

  @Test("Cancellation during approval prevents the side effect from starting")
  func cancellationDuringAuthorization() async throws {
    let counter = InvocationCounter()
    let signal = AuthorizationSignal()
    let approval = ClosureCoreAgentApprovalProvider { _ in
      await signal.markStarted()
      try? await Task.sleep(for: .seconds(1))
      return .approve
    }
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(name: "echo", argumentsJSON: #"{"value":"never"}"#)
      ]),
      tools: [EchoTool(counter: counter)],
      toolConfiguration: .init(
        policy: ApprovalRequiredToolPolicy(provider: approval)
      )
    )
    let run = Task { try await session.respond(to: "Use echo") }
    while !(await signal.started) {
      await Task.yield()
    }

    run.cancel()

    await #expect(throws: (any Error).self) {
      _ = try await run.value
    }
    #expect(await counter.count == 0)
    let completedRun = try #require(await session.lastRun())
    #expect(completedRun.events.contains { $0.kind == .toolAuthorizationCancelled })
    #expect(!completedRun.events.contains { $0.kind == .toolAuthorizationDenied })
  }

  @Test("Does not label an authorization service error as a denial or retry it")
  func authorizationFailureStopsRetry() async throws {
    let retry = try CoreAgentRetryPolicy(maximumAttempts: 2) { _ in true }
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"blocked"}"#),
      .response(text: "must not retry"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [EchoTool(counter: InvocationCounter())],
      configuration: .init(retryPolicy: retry),
      toolConfiguration: .init(policy: FailingAuthorizationPolicy())
    )

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo")
    }

    #expect(model.recorder.capturedTranscripts().count == 1)
    let run = try #require(await session.lastRun())
    #expect(run.events.filter { $0.kind == .modelAttemptStarted }.count == 1)
    #expect(run.events.contains { $0.kind == .toolAuthorizationFailed })
    #expect(!run.events.contains { $0.kind == .toolAuthorizationDenied })
  }

  @Test("Enforces a total native tool-call budget")
  func toolCallBudget() async throws {
    let counter = InvocationCounter()
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"first"}"#),
      .toolCall(name: "echo", argumentsJSON: #"{"value":"second"}"#),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [EchoTool(counter: counter)],
      toolConfiguration: .init(maximumCallsPerRun: 1)
    )

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Call twice")
    }

    #expect(await counter.count == 1)
    #expect(await counter.values == ["first"])
  }

  @Test("Preserves a native tool's schema-in-instructions opt-out")
  func toolSchemaInstructionPreference() throws {
    let manifest = try CoreAgentToolManifest(tool: SchemaHiddenEchoTool())

    #expect(!manifest.includesSchemaInInstructions)
  }

  @Test("Times out a cooperative native tool execution")
  func toolExecutionTimeout() async throws {
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "slow_echo", argumentsJSON: #"{"value":"late"}"#)
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [SlowEchoTool()],
      toolConfiguration: .init(executionTimeout: .milliseconds(10))
    )

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use the slow tool")
    }

    let run = try #require(await session.lastRun())
    #expect(run.events.contains { $0.kind == .toolExecutionFailed })
  }

  @Test("Trusts the exact native tool manifest and rejects a changed contract")
  func trustedToolManifest() async throws {
    let counter = InvocationCounter()
    let tool = EchoTool(counter: counter)
    let manifest = try CoreAgentToolManifest(tool: tool)
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"trusted"}"#),
      .response(text: "done"),
    ])
    let trusted = try CoreAgentSession(
      model: model,
      tools: [tool],
      toolConfiguration: .init(
        policy: TrustedToolManifestPolicy(approvedManifests: [manifest])
      )
    )

    #expect(try await trusted.respond(to: "Use echo").content == "done")
    #expect(await counter.count == 1)

    let denied = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(name: "echo", argumentsJSON: #"{"value":"denied"}"#)
      ]),
      tools: [EchoTool(counter: counter)],
      toolConfiguration: .init(
        policy: TrustedToolManifestPolicy(approvedDigests: ["outdated"])
      )
    )
    await #expect(throws: (any Error).self) {
      _ = try await denied.respond(to: "Use echo")
    }
    #expect(await counter.count == 1)
  }

  @Test("Retries only when the configured classifier permits it")
  func retryPolicy() async throws {
    let retry = try CoreAgentRetryPolicy(maximumAttempts: 2) { _ in true }
    let model = RecordedLanguageModel(steps: [
      .failure("temporary"),
      .response(text: "recovered"),
    ])
    let session = try CoreAgentSession(
      model: model,
      configuration: .init(retryPolicy: retry)
    )

    let response = try await session.respond(to: "Retry")

    #expect(response.content == "recovered")
    #expect(response.run.events.filter { $0.kind == .modelAttemptStarted }.count == 2)
    #expect(response.run.events.filter { $0.kind == .modelAttemptFailed }.count == 1)
  }

  @Test("Does not retry automatically after a side-effecting tool began")
  func retrySuppressedAfterToolExecution() async throws {
    let counter = InvocationCounter()
    let retry = try CoreAgentRetryPolicy(maximumAttempts: 2) { _ in true }
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"once"}"#),
      .failure("failed after the side effect"),
      .toolCall(name: "echo", argumentsJSON: #"{"value":"twice"}"#),
      .response(text: "should not happen"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [EchoTool(counter: counter)],
      configuration: .init(retryPolicy: retry)
    )

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo")
    }

    #expect(await counter.count == 1)
    #expect(await counter.values == ["once"])
  }

  @Test("Cancels a model response at the configured timeout")
  func responseTimeout() async throws {
    let model = RecordedLanguageModel(
      steps: [.delayedResponse(text: "late", delay: .seconds(1))]
    )
    let session = try CoreAgentSession(
      model: model,
      configuration: .init(responseTimeout: .milliseconds(10))
    )

    await #expect(throws: CoreAgentError.self) {
      _ = try await session.respond(to: "Timeout")
    }
  }

  @Test("Rejects overlapping runs before they can corrupt tool attribution")
  func concurrentRunGate() async throws {
    let model = RecordedLanguageModel(
      steps: [.delayedResponse(text: "first", delay: .milliseconds(50))]
    )
    let session = try CoreAgentSession(model: model)
    let first = Task { try await session.respond(to: "First") }
    while model.recorder.capturedTranscripts().isEmpty {
      await Task.yield()
    }

    await #expect(throws: CoreAgentError.self) {
      _ = try await session.respond(to: "Second")
    }

    #expect(try await first.value.content == "first")
  }

  @Test("Streams partial native responses and returns the final run")
  func streamingResponse() async throws {
    let model = RecordedLanguageModel(steps: [.response(text: "streamed")])
    let session = try CoreAgentSession(model: model)
    let capture = StringCapture()

    let response = try await session.respondStreaming(to: Prompt("Stream")) {
      await capture.append($0)
    }

    #expect(response.content == "streamed")
    #expect(await capture.values.last == "streamed")
    #expect(response.run.events.last?.kind == .runCompleted)
  }

  @Test("Applies response timeout to streaming")
  func streamingTimeout() async throws {
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(
        steps: [.delayedResponse(text: "late", delay: .seconds(1))]
      ),
      configuration: .init(responseTimeout: .milliseconds(10))
    )

    await #expect(throws: CoreAgentError.self) {
      _ = try await session.respondStreaming(to: Prompt("Timeout")) { _ in }
    }
  }

  @Test("Retries a stream only before its first partial response")
  func streamingRetryBeforePartial() async throws {
    let retry = try CoreAgentRetryPolicy(maximumAttempts: 2) { _ in true }
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .failure("temporary"),
        .response(text: "recovered stream"),
      ]),
      configuration: .init(retryPolicy: retry)
    )
    let partials = StringCapture()

    let response = try await session.respondStreaming(to: Prompt("Retry")) {
      await partials.append($0)
    }

    #expect(response.content == "recovered stream")
    #expect(await partials.values.last == "recovered stream")
    #expect(response.run.events.filter { $0.kind == .modelAttemptStarted }.count == 2)
  }

  @Test("Streams typed output across multiple provider fragments")
  func typedStreamingFragments() async throws {
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .responseFragments(["{\"value\":\"", "typed\"}"])
      ])
    )
    let partials = PartialCount()

    let response = try await session.respondStreaming(
      to: Prompt("Typed"),
      generating: TestAnswer.self
    ) { _ in
      await partials.increment()
    }

    #expect(response.content.value == "typed")
    #expect(await partials.value >= 1)
  }

  @Test("Restores a versioned native transcript checkpoint")
  func checkpointRestore() async throws {
    let store = InMemoryCheckpointStore()
    let firstModel = RecordedLanguageModel(steps: [.response(text: "first")])
    let first = try CoreAgentSession(
      model: firstModel,
      instructions: Instructions("Persist this instruction."),
      checkpointStore: store,
      checkpointKey: "conversation"
    )
    _ = try await first.respond(to: "One")

    let secondModel = RecordedLanguageModel(steps: [.response(text: "second")])
    let second = try CoreAgentSession(
      model: secondModel,
      checkpointStore: store,
      checkpointKey: "conversation"
    )
    _ = try await second.respond(to: "Two")

    let restoredRequest = try #require(secondModel.recorder.capturedTranscripts().first)
    #expect(restoredRequest.count >= 3)
    #expect(
      restoredRequest.contains { entry in
        if case .instructions = entry { return true }
        return false
      })
  }

}

actor StringCapture {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}
