import CoreGraphics
import CryptoKit
import Foundation
import FoundationModels
import FoundationModelsAgent
import FoundationModelsAgentTestSupport
import Testing

@Generable
private struct TestAnswer: Sendable {
  let value: String
}

@Generable
private struct EchoArguments: Sendable {
  let value: String
}

private actor InvocationCounter {
  private(set) var count = 0
  private(set) var values: [String] = []

  func record(_ value: String) {
    count += 1
    values.append(value)
  }
}

private struct EchoTool: Tool {
  let counter: InvocationCounter
  let name = "echo"
  let description = "Returns the supplied value."

  @concurrent
  func call(arguments: EchoArguments) async throws -> String {
    await counter.record(arguments.value)
    return arguments.value
  }
}

private struct SlowEchoTool: Tool {
  let name = "slow_echo"
  let description = "Returns the supplied value after a delay."

  @concurrent
  func call(arguments: EchoArguments) async throws -> String {
    try await Task.sleep(for: .seconds(1))
    return arguments.value
  }
}

private struct SchemaHiddenEchoTool: Tool {
  let name = "schema_hidden_echo"
  let description = "Keeps its argument schema out of instructions."
  let includesSchemaInInstructions = false

  @concurrent
  func call(arguments: EchoArguments) async throws -> String {
    arguments.value
  }
}

private struct TestDynamicProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel
  let instructions: String

  init(
    model: RecordedLanguageModel,
    instructions: String = "Dynamic profile instructions."
  ) {
    self.model = model
    self.instructions = instructions
  }

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions(instructions)
    }
    .model(model)
  }
}

private struct TestToolDynamicProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel
  let tool: EchoTool

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Use the echo tool.")
      tool
    }
    .model(model)
  }
}

private struct ChangedEchoTool: Tool {
  let counter: InvocationCounter
  let name = "echo"
  let description = "A changed echo contract that must be trusted independently."

  @concurrent
  func call(arguments: EchoArguments) async throws -> String {
    await counter.record(arguments.value)
    return arguments.value
  }
}

@Generable
private struct PairArguments: Sendable {
  let zebra: String
  let alpha: String
}

private struct PairTool: Tool {
  let counter: InvocationCounter
  let name = "pair"
  let description = "Returns two supplied values."

  @concurrent
  func call(arguments: PairArguments) async throws -> String {
    let value = "\(arguments.alpha):\(arguments.zebra)"
    await counter.record(value)
    return value
  }
}

private struct PairToolDynamicProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel
  let tool: PairTool

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Use the pair tool.")
      tool
    }
    .model(model)
  }
}

private struct ChangedToolDynamicProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel
  let tool: ChangedEchoTool

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Use the changed echo tool.")
      tool
    }
    .model(model)
  }
}

private actor ProfileAuthorizationCapture {
  private(set) var requests: [DynamicProfileToolAuthorizationRequest] = []

  func append(_ request: DynamicProfileToolAuthorizationRequest) {
    requests.append(request)
  }
}

private actor LifecycleOrderCapture {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private struct OrderedEchoTool: Tool {
  let order: LifecycleOrderCapture
  let name = "ordered_echo"
  let description = "Records native lifecycle ordering."

  @concurrent
  func call(arguments: EchoArguments) async throws -> String {
    await order.append("tool")
    return arguments.value
  }
}

private struct OrderedToolDynamicProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel
  let tool: OrderedEchoTool
  let order: LifecycleOrderCapture

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Use the ordered echo tool.")
      tool
    }
    .model(model)
    .onToolCall { _ in
      await order.append("inner")
    }
  }
}

private enum ProfileLifecycleError: Error {
  case intentional
}

private struct ThrowingLifecycleDynamicProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel
  let tool: EchoTool

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Use the echo tool.")
      tool
    }
    .model(model)
    .onToolOutput { _, _ in
      throw ProfileLifecycleError.intentional
    }
  }
}

private final class NonSendableProfileState {
  let instructions: String

  init(instructions: String) {
    self.instructions = instructions
  }
}

private struct NonSendableStateProfile: LanguageModelSession.DynamicProfile {
  let state: NonSendableProfileState
  let model: RecordedLanguageModel

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions(state.instructions)
    }
    .model(model)
  }
}

private final class ProfileFactoryCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() {
    lock.withLock { value += 1 }
  }

  var count: Int {
    lock.withLock { value }
  }
}

private struct TestCustomSegment: Transcript.CustomSegment {
  struct Content: Codable, Equatable, Sendable {
    let value: String
  }

  let id: String
  let content: Content
}

private actor RequestCapture {
  private(set) var requests: [FoundationModelsAgentToolRequest] = []

  func append(_ request: FoundationModelsAgentToolRequest) {
    requests.append(request)
  }
}

private actor EventCapture {
  private(set) var events: [FoundationModelsAgentEvent] = []

  func append(_ event: FoundationModelsAgentEvent) {
    events.append(event)
  }
}

private actor PartialCount {
  private(set) var value = 0

  func increment() {
    value += 1
  }
}

private actor AuthorizationSignal {
  private(set) var started = false

  func markStarted() {
    started = true
  }
}

private enum AuthorizationServiceError: Error {
  case unavailable
}

private struct FailingAuthorizationPolicy: FoundationModelsAgentToolPolicy {
  func authorize(_ request: FoundationModelsAgentToolRequest) async throws {
    throw AuthorizationServiceError.unavailable
  }
}

private enum RetentionError: Error {
  case shouldNotRunAutomatically
}

private actor ObserverGate {
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

private actor BooleanCapture {
  private(set) var values: [Bool] = []

  func append(_ value: Bool) {
    values.append(value)
  }
}

private actor SessionReference {
  private var session: AgentSession?

  func set(_ session: AgentSession) {
    self.session = session
  }

  func get() -> AgentSession? {
    session
  }
}

private enum FailingCheckpointError: Error {
  case intentional
}

private actor FailingCheckpointStore: FoundationModelsAgentCheckpointStore {
  func loadCheckpoint(for key: String) throws -> FoundationModelsAgentCheckpoint? {
    nil
  }

  func saveCheckpoint(_ checkpoint: FoundationModelsAgentCheckpoint, for key: String) throws {
    throw FailingCheckpointError.intentional
  }

  func removeCheckpoint(for key: String) throws {}
}

@Suite("FoundationModelsAgent native Foundation Models runtime")
struct FoundationModelsAgentTests {
  @Test("Uses native instructions, responses, usage, and receipts")
  func nativeTextResponse() async throws {
    let model = RecordedLanguageModel(
      steps: [.response(text: "hello", inputTokens: 4, outputTokens: 2)]
    )
    let session = try AgentSession(
      model: model,
      instructions: Instructions("Always be concise.")
    )

    let response = try await session.respond(to: "Say hello")

    #expect(response.content == "hello")
    #expect(response.usage.inputTokens == 4)
    #expect(response.usage.outputTokens == 2)
    #expect(response.run.events.first?.kind == .runStarted)
    #expect(response.run.events.last?.kind == .runCompleted)
    #expect(try FoundationModelsAgentRunReceipt(run: response.run).verify())

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
    let session = try AgentSession(model: model)

    let response = try await session.respond(to: "Return a value", generating: TestAnswer.self)

    #expect(response.content.value == "typed")
    #expect(response.rawContent.jsonString.contains("typed"))
  }

  @Test("Passes image attachments through the native prompt")
  func imagePromptIsNotFlattened() async throws {
    let model = RecordedLanguageModel(steps: [.response(text: "seen")], capabilities: [.vision])
    let session = try AgentSession(model: model)
    let context = try #require(
      CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    let image = try #require(context.makeImage())
    let prompt = Prompt {
      "Inspect this image."
      Attachment(image).label("fixture")
    }

    _ = try await session.respond(to: prompt)

    let transcript = try #require(model.recorder.capturedTranscripts().first)
    let hasAttachment = transcript.contains { entry in
      guard case .prompt(let prompt) = entry else { return false }
      return prompt.segments.contains { segment in
        if case .attachment = segment { return true }
        return false
      }
    }
    #expect(hasAttachment)
  }

  @Test("Authorizes native tool arguments and executes the tool once")
  func governedToolRoundTrip() async throws {
    let counter = InvocationCounter()
    let capture = RequestCapture()
    let approval = ClosureFoundationModelsAgentApprovalProvider { request in
      await capture.append(request)
      return .approve
    }
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"approved"}"#),
      .response(text: "done"),
    ])
    let session = try AgentSession(
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
    let session = try AgentSession(
      model: model,
      tools: [EchoTool(counter: counter)],
      toolConfiguration: .init(
        policy: ApprovalRequiredToolPolicy(
          provider: ClosureFoundationModelsAgentApprovalProvider { _ in
            .deny(reason: "User declined")
          }
        )
      ),
      observers: [ClosureFoundationModelsAgentObserver { await eventCapture.append($0) }]
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
    let approval = ClosureFoundationModelsAgentApprovalProvider { _ in
      await signal.markStarted()
      try? await Task.sleep(for: .seconds(1))
      return .approve
    }
    let session = try AgentSession(
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
    let retry = try FoundationModelsAgentRetryPolicy(maximumAttempts: 2) { _ in true }
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"blocked"}"#),
      .response(text: "must not retry"),
    ])
    let session = try AgentSession(
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
    let session = try AgentSession(
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
    let manifest = try FoundationModelsAgentToolManifest(tool: SchemaHiddenEchoTool())

    #expect(!manifest.includesSchemaInInstructions)
  }

  @Test("Times out a cooperative native tool execution")
  func toolExecutionTimeout() async throws {
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "slow_echo", argumentsJSON: #"{"value":"late"}"#)
    ])
    let session = try AgentSession(
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
    let manifest = try FoundationModelsAgentToolManifest(tool: tool)
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"trusted"}"#),
      .response(text: "done"),
    ])
    let trusted = try AgentSession(
      model: model,
      tools: [tool],
      toolConfiguration: .init(
        policy: TrustedToolManifestPolicy(approvedManifests: [manifest])
      )
    )

    #expect(try await trusted.respond(to: "Use echo").content == "done")
    #expect(await counter.count == 1)

    let denied = try AgentSession(
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
    let retry = try FoundationModelsAgentRetryPolicy(maximumAttempts: 2) { _ in true }
    let model = RecordedLanguageModel(steps: [
      .failure("temporary"),
      .response(text: "recovered"),
    ])
    let session = try AgentSession(
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
    let retry = try FoundationModelsAgentRetryPolicy(maximumAttempts: 2) { _ in true }
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"once"}"#),
      .failure("failed after the side effect"),
      .toolCall(name: "echo", argumentsJSON: #"{"value":"twice"}"#),
      .response(text: "should not happen"),
    ])
    let session = try AgentSession(
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
    let session = try AgentSession(
      model: model,
      configuration: .init(responseTimeout: .milliseconds(10))
    )

    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await session.respond(to: "Timeout")
    }
  }

  @Test("Rejects overlapping runs before they can corrupt tool attribution")
  func concurrentRunGate() async throws {
    let model = RecordedLanguageModel(
      steps: [.delayedResponse(text: "first", delay: .milliseconds(50))]
    )
    let session = try AgentSession(model: model)
    let first = Task { try await session.respond(to: "First") }
    while model.recorder.capturedTranscripts().isEmpty {
      await Task.yield()
    }

    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await session.respond(to: "Second")
    }

    #expect(try await first.value.content == "first")
  }

  @Test("Streams partial native responses and returns the final run")
  func streamingResponse() async throws {
    let model = RecordedLanguageModel(steps: [.response(text: "streamed")])
    let session = try AgentSession(model: model)
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
    let session = try AgentSession(
      model: RecordedLanguageModel(
        steps: [.delayedResponse(text: "late", delay: .seconds(1))]
      ),
      configuration: .init(responseTimeout: .milliseconds(10))
    )

    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await session.respondStreaming(to: Prompt("Timeout")) { _ in }
    }
  }

  @Test("Retries a stream only before its first partial response")
  func streamingRetryBeforePartial() async throws {
    let retry = try FoundationModelsAgentRetryPolicy(maximumAttempts: 2) { _ in true }
    let session = try AgentSession(
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
    let session = try AgentSession(
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
    let first = try AgentSession(
      model: firstModel,
      instructions: Instructions("Persist this instruction."),
      checkpointStore: store,
      checkpointKey: "conversation"
    )
    _ = try await first.respond(to: "One")

    let secondModel = RecordedLanguageModel(steps: [.response(text: "second")])
    let second = try AgentSession(
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

  @Test("Recreates a dynamic profile and restores only its native history")
  func dynamicProfileRestore() async throws {
    let store = InMemoryCheckpointStore()
    let firstModel = RecordedLanguageModel(steps: [.response(text: "first")])
    let first = try AgentSession(
      checkpointCompatibilityID: "assistant-profile-v1",
      checkpointStore: store,
      checkpointKey: "dynamic-profile"
    ) {
      TestDynamicProfile(model: firstModel, instructions: "Old profile instructions.")
    }
    _ = try await first.respond(to: "One")

    let secondModel = RecordedLanguageModel(steps: [.response(text: "second")])
    let second = try AgentSession(
      checkpointCompatibilityID: "assistant-profile-v1",
      checkpointStore: store,
      checkpointKey: "dynamic-profile"
    ) {
      TestDynamicProfile(model: secondModel, instructions: "New profile instructions.")
    }
    _ = try await second.respond(to: "Two")

    let restored = try #require(secondModel.recorder.capturedTranscripts().first)
    #expect(restored.history.count >= 3)
    let instructionText = restored.compactMap { entry -> String? in
      guard case .instructions(let instructions) = entry else { return nil }
      return instructions.segments.compactMap { segment in
        guard case .text(let text) = segment else { return nil }
        return text.content
      }.joined(separator: " ")
    }.joined(separator: " ")
    #expect(instructionText.contains("New profile instructions."))
    #expect(!instructionText.contains("Old profile instructions."))

    let incompatible = try AgentSession(
      checkpointCompatibilityID: "assistant-profile-v2",
      checkpointStore: store,
      checkpointKey: "dynamic-profile"
    ) {
      TestDynamicProfile(model: RecordedLanguageModel(steps: [.response(text: "unused")]))
    }
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await incompatible.respond(to: "Mismatch")
    }
  }

  @Test("Restores a dynamic profile checkpoint from the previous revision salt")
  func dynamicProfilePreviousRevisionRestore() async throws {
    let compatibilityID = "assistant-profile-v1"
    let previousSalt = ["core", "agent-profile-v1"].joined()
    let previousRevision = SHA256.hash(
      data: Data("\(previousSalt)\u{0}\(compatibilityID)".utf8)
    )
    .map { String(format: "%02x", $0) }
    .joined()
    let checkpoint = FoundationModelsAgentCheckpoint(
      compatibilityRevision: previousRevision,
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "Previous conversation"))]))
      ])
    )
    let store = InMemoryCheckpointStore(checkpoints: ["previous-profile": checkpoint])
    let model = RecordedLanguageModel(steps: [.response(text: "restored")])
    let session = try AgentSession(
      checkpointCompatibilityID: compatibilityID,
      checkpointStore: store,
      checkpointKey: "previous-profile"
    ) {
      TestDynamicProfile(model: model)
    }

    _ = try await session.respond(to: "Continue")

    let restored = try #require(model.recorder.capturedTranscripts().first)
    #expect(
      restored.contains { entry in
        guard case .prompt(let prompt) = entry else { return false }
        return prompt.segments.contains { segment in
          guard case .text(let text) = segment else { return false }
          return text.content == "Previous conversation"
        }
      }
    )
    let migrated = try #require(await store.loadCheckpoint(for: "previous-profile"))
    #expect(migrated.compatibilityRevision != previousRevision)
  }

  @Test("Creates fresh non-Sendable profile state when rebuilding on reset")
  func dynamicProfileSendingFactory() async throws {
    let counter = ProfileFactoryCounter()
    let model = RecordedLanguageModel(steps: [])
    let session = try AgentSession(
      checkpointCompatibilityID: "stateful-profile-v1"
    ) {
      counter.increment()
      return NonSendableStateProfile(
        state: NonSendableProfileState(instructions: "Stateful profile instructions."),
        model: model
      )
    }

    _ = try await session.transcript()
    try await session.reset()

    #expect(counter.count == 2)
  }

  @Test("Rejects retries for an opaque dynamic profile")
  func dynamicProfileRetrySafety() throws {
    let retry = try FoundationModelsAgentRetryPolicy(maximumAttempts: 2) { _ in true }

    #expect(throws: FoundationModelsAgentError.self) {
      _ = try AgentSession(
        checkpointCompatibilityID: "profile-v1",
        configuration: .init(
          retryPolicy: retry,
          allowsRetryAfterToolInvocation: true
        )
      ) {
        TestDynamicProfile(
          model: RecordedLanguageModel(steps: [.response(text: "unused")])
        )
      }
    }
  }

  @Test("Audits a profile-owned tool even when the model continuation fails")
  func dynamicProfileFailedToolAudit() async throws {
    let counter = InvocationCounter()
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"side-effect"}"#),
      .failure("continuation failed"),
    ])
    let session = try AgentSession(
      checkpointCompatibilityID: "tool-profile-v1"
    ) {
      TestToolDynamicProfile(
        model: model,
        tool: EchoTool(counter: counter)
      )
    }

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo")
    }

    #expect(await counter.count == 1)
    let run = try #require(await session.lastRun())
    #expect(run.events.contains { $0.kind == .nativeToolCallRecorded })
    #expect(run.events.contains { $0.kind == .nativeToolOutputRecorded })
    #expect(run.events.last?.kind == .runFailed)
  }

  @Test("Marks profile tool audit as best effort when an inner hook hides its output")
  func dynamicProfileLifecycleAuditBoundary() async throws {
    let counter = InvocationCounter()
    let session = try AgentSession(
      checkpointCompatibilityID: "throwing-hook-profile-v1"
    ) {
      ThrowingLifecycleDynamicProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(name: "echo", argumentsJSON: #"{"value":"side-effect"}"#)
        ]),
        tool: EchoTool(counter: counter)
      )
    }

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo")
    }

    #expect(await counter.count == 1)
    let run = try #require(await session.lastRun())
    #expect(run.events.contains { $0.kind == .profileToolAuditBestEffort })
    #expect(run.events.contains { $0.kind == .nativeToolCallRecorded })
    #expect(!run.events.contains { $0.kind == .nativeToolOutputRecorded })
  }

  @Test("Allows a trusted profile tool using canonical native arguments")
  func governedDynamicProfileAllowsTrustedTool() async throws {
    let counter = InvocationCounter()
    let capture = ProfileAuthorizationCapture()
    let tool = PairTool(counter: counter)
    let registry = try DynamicProfileToolRegistry(tools: [tool])
    let configuration = try DynamicProfileToolGovernanceConfiguration(
      trusting: registry,
      authorizer: ClosureDynamicProfileToolAuthorizer { request in
        await capture.append(request)
        return .allow
      },
      maximumCallsPerRun: 1,
      maximumCallsPerToolPerRun: ["pair": 1]
    )
    let session = try AgentSession(
      checkpointCompatibilityID: "governed-pair-profile-v1",
      toolGovernance: configuration
    ) {
      PairToolDynamicProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(
            id: "native-allow",
            name: "pair",
            argumentsJSON: #"{"zebra":"last","alpha":"first"}"#
          ),
          .response(text: "done"),
        ]),
        tool: tool
      )
    }

    let response = try await session.respond(to: "Use pair")

    #expect(response.content == "done")
    #expect(await counter.values == ["first:last"])
    #expect(await capture.requests.first?.nativeCallID == "native-allow")
    #expect(
      await capture.requests.first?.canonicalArgumentsJSON
        == #"{"alpha":"first","zebra":"last"}"#
    )
    #expect(
      response.run.events.contains {
        $0.kind == .profileToolAllowed
          && $0.attributes["native_call_id"] == "native-allow"
      }
    )
    #expect(response.run.routingDecision == nil)
    #expect(
      !response.run.events.contains {
        $0.kind == .routeSelected || $0.kind == .routeCandidateRejected
      }
    )
  }

  @Test("Denial in profile governance prevents the native tool implementation")
  func governedDynamicProfileDenial() async throws {
    let counter = InvocationCounter()
    let tool = EchoTool(counter: counter)
    let registry = try DynamicProfileToolRegistry(tools: [tool])
    let configuration = try DynamicProfileToolGovernanceConfiguration(
      trusting: registry,
      authorizer: ClosureDynamicProfileToolAuthorizer { _ in
        .deny(reason: "User declined")
      }
    )
    let session = try AgentSession(
      checkpointCompatibilityID: "governed-denial-profile-v1",
      toolGovernance: configuration
    ) {
      TestToolDynamicProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(
            id: "native-denied",
            name: "echo",
            argumentsJSON: #"{"value":"blocked"}"#
          )
        ]),
        tool: tool
      )
    }

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo")
    }

    #expect(await counter.count == 0)
    let run = try #require(await session.lastRun())
    #expect(
      run.events.contains {
        $0.kind == .profileToolDenied
          && $0.attributes["native_call_id"] == "native-denied"
      }
    )
  }

  @Test("Approval failure is distinct from a policy denial")
  func governedDynamicProfileApprovalFailure() async throws {
    let counter = InvocationCounter()
    let tool = EchoTool(counter: counter)
    let registry = try DynamicProfileToolRegistry(tools: [tool])
    let configuration = try DynamicProfileToolGovernanceConfiguration(
      trusting: registry,
      authorizer: ClosureDynamicProfileToolAuthorizer { _ in
        throw AuthorizationServiceError.unavailable
      }
    )
    let session = try AgentSession(
      checkpointCompatibilityID: "governed-approval-failure-profile-v1",
      toolGovernance: configuration
    ) {
      TestToolDynamicProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(
            id: "native-approval-failed",
            name: "echo",
            argumentsJSON: #"{"value":"blocked"}"#
          )
        ]),
        tool: tool
      )
    }

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo")
    }

    #expect(await counter.count == 0)
    let run = try #require(await session.lastRun())
    #expect(
      run.events.contains {
        $0.kind == .profileToolApprovalFailed
          && $0.attributes["native_call_id"] == "native-approval-failed"
      }
    )
    #expect(!run.events.contains { $0.kind == .profileToolDenied })
  }

  @Test("An unknown profile tool fails closed")
  func governedDynamicProfileUnknownTool() async throws {
    let counter = InvocationCounter()
    let registry = try DynamicProfileToolRegistry(manifests: [])
    let configuration = try DynamicProfileToolGovernanceConfiguration(trusting: registry)
    let session = try AgentSession(
      checkpointCompatibilityID: "governed-unknown-profile-v1",
      toolGovernance: configuration
    ) {
      TestToolDynamicProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(
            id: "native-unknown",
            name: "echo",
            argumentsJSON: #"{"value":"blocked"}"#
          )
        ]),
        tool: EchoTool(counter: counter)
      )
    }

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo")
    }

    #expect(await counter.count == 0)
    let run = try #require(await session.lastRun())
    #expect(
      run.events.contains {
        $0.kind == .profileToolDenied
          && $0.attributes["native_call_id"] == "native-unknown"
      }
    )
  }

  @Test("A changed profile manifest does not inherit prior trust")
  func governedDynamicProfileChangedManifest() async throws {
    let counter = InvocationCounter()
    let priorManifest = try FoundationModelsAgentToolManifest(
      tool: EchoTool(counter: counter)
    )
    let changedTool = ChangedEchoTool(counter: counter)
    let changedRegistry = try DynamicProfileToolRegistry(tools: [changedTool])
    let configuration = try DynamicProfileToolGovernanceConfiguration(
      registry: changedRegistry,
      trustedManifestDigests: [priorManifest.digest]
    )
    let session = try AgentSession(
      checkpointCompatibilityID: "governed-changed-manifest-profile-v1",
      toolGovernance: configuration
    ) {
      ChangedToolDynamicProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(
            id: "native-changed",
            name: "echo",
            argumentsJSON: #"{"value":"blocked"}"#
          )
        ]),
        tool: changedTool
      )
    }

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo")
    }

    #expect(await counter.count == 0)
    let run = try #require(await session.lastRun())
    #expect(
      run.events.contains {
        $0.kind == .profileToolDenied
          && $0.attributes["manifest_digest"] == changedRegistry.manifests.first?.digest
      }
    )
  }

  @Test("Profile governance enforces the total call budget before execution")
  func governedDynamicProfileTotalBudget() async throws {
    let counter = InvocationCounter()
    let tool = EchoTool(counter: counter)
    let registry = try DynamicProfileToolRegistry(tools: [tool])
    let configuration = try DynamicProfileToolGovernanceConfiguration(
      trusting: registry,
      maximumCallsPerRun: 1,
      maximumCallsPerToolPerRun: ["echo": 2]
    )
    let session = try AgentSession(
      checkpointCompatibilityID: "governed-total-budget-profile-v1",
      toolGovernance: configuration
    ) {
      TestToolDynamicProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(name: "echo", argumentsJSON: #"{"value":"first"}"#),
          .toolCall(
            id: "native-total-exhausted",
            name: "echo",
            argumentsJSON: #"{"value":"second"}"#
          ),
        ]),
        tool: tool
      )
    }

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo twice")
    }

    #expect(await counter.values == ["first"])
    let run = try #require(await session.lastRun())
    #expect(
      run.events.contains {
        $0.kind == .profileToolBudgetExhausted
          && $0.attributes["native_call_id"] == "native-total-exhausted"
      }
    )
  }

  @Test("Profile governance enforces a per-tool call budget before execution")
  func governedDynamicProfilePerToolBudget() async throws {
    let counter = InvocationCounter()
    let tool = EchoTool(counter: counter)
    let registry = try DynamicProfileToolRegistry(tools: [tool])
    let configuration = try DynamicProfileToolGovernanceConfiguration(
      trusting: registry,
      maximumCallsPerRun: 2,
      maximumCallsPerToolPerRun: ["echo": 1]
    )
    let session = try AgentSession(
      checkpointCompatibilityID: "governed-per-tool-budget-profile-v1",
      toolGovernance: configuration
    ) {
      TestToolDynamicProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(name: "echo", argumentsJSON: #"{"value":"first"}"#),
          .toolCall(
            id: "native-tool-exhausted",
            name: "echo",
            argumentsJSON: #"{"value":"second"}"#
          ),
        ]),
        tool: tool
      )
    }

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo twice")
    }

    #expect(await counter.values == ["first"])
    let run = try #require(await session.lastRun())
    #expect(
      run.events.contains {
        $0.kind == .profileToolBudgetExhausted
          && $0.attributes["native_call_id"] == "native-tool-exhausted"
      }
    )
  }

  @Test("Cancellation during profile approval prevents execution")
  func governedDynamicProfileCancellationDuringApproval() async throws {
    let counter = InvocationCounter()
    let signal = AuthorizationSignal()
    let tool = EchoTool(counter: counter)
    let registry = try DynamicProfileToolRegistry(tools: [tool])
    let configuration = try DynamicProfileToolGovernanceConfiguration(
      trusting: registry,
      authorizer: ClosureDynamicProfileToolAuthorizer { _ in
        await signal.markStarted()
        try await Task.sleep(for: .seconds(1))
        return .allow
      }
    )
    let session = try AgentSession(
      checkpointCompatibilityID: "governed-cancellation-profile-v1",
      toolGovernance: configuration
    ) {
      TestToolDynamicProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(
            id: "native-cancelled",
            name: "echo",
            argumentsJSON: #"{"value":"never"}"#
          )
        ]),
        tool: tool
      )
    }
    let task = Task { try await session.respond(to: "Use echo") }
    while !(await signal.started) {
      await Task.yield()
    }

    task.cancel()

    await #expect(throws: (any Error).self) {
      _ = try await task.value
    }
    #expect(await counter.count == 0)
    let run = try #require(await session.lastRun())
    #expect(
      run.events.contains {
        $0.kind == .profileToolApprovalFailed
          && $0.attributes["native_call_id"] == "native-cancelled"
      }
    )
  }

  @Test("Supplied inner tool-call hooks run before outer governance and execution")
  func governedDynamicProfileLifecycleOrdering() async throws {
    let order = LifecycleOrderCapture()
    let tool = OrderedEchoTool(order: order)
    let registry = try DynamicProfileToolRegistry(tools: [tool])
    let configuration = try DynamicProfileToolGovernanceConfiguration(
      trusting: registry,
      authorizer: ClosureDynamicProfileToolAuthorizer { _ in
        await order.append("governance")
        return .allow
      }
    )
    let session = try AgentSession(
      checkpointCompatibilityID: "governed-ordering-profile-v1",
      toolGovernance: configuration
    ) {
      OrderedToolDynamicProfile(
        model: RecordedLanguageModel(steps: [
          .toolCall(
            name: "ordered_echo",
            argumentsJSON: #"{"value":"ordered"}"#
          ),
          .response(text: "done"),
        ]),
        tool: tool,
        order: order
      )
    }

    _ = try await session.respond(to: "Use ordered echo")

    #expect(await order.values == ["inner", "governance", "tool"])
  }

  @Test("Applies bounded transcript retention only to persisted history")
  func transcriptRetention() async throws {
    let store = InMemoryCheckpointStore()
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "one"),
        .response(text: "two"),
      ]),
      instructions: Instructions("Retain me."),
      checkpointStore: store,
      checkpointKey: "bounded",
      transcriptRetention: .latestHistoryEntries(2)
    )

    _ = try await session.respond(to: "First")
    _ = try await session.respond(to: "Second")

    let checkpoint = try #require(await store.loadCheckpoint(for: "bounded"))
    #expect(checkpoint.transcript.history.count == 2)
    #expect(
      checkpoint.transcript.contains { entry in
        if case .instructions = entry { return true }
        return false
      })
    #expect(try await session.transcript().history.count > 2)
  }

  @Test("Never truncates persisted history into an orphaned tool turn")
  func transcriptRetentionKeepsTurnBoundaries() async throws {
    let store = InMemoryCheckpointStore()
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(name: "echo", argumentsJSON: #"{"value":"turn"}"#),
        .response(text: "done"),
      ]),
      tools: [EchoTool(counter: InvocationCounter())],
      checkpointStore: store,
      checkpointKey: "tool-turn",
      transcriptRetention: .latestHistoryEntries(2)
    )

    _ = try await session.respond(to: "Use echo")

    let checkpoint = try #require(await store.loadCheckpoint(for: "tool-turn"))
    #expect(checkpoint.transcript.history.isEmpty)
  }

  @Test("Replaces restored instructions when current instructions are supplied")
  func instructionRebasing() async throws {
    let store = InMemoryCheckpointStore()
    let first = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "saved")]),
      instructions: Instructions("Old instructions"),
      checkpointStore: store,
      checkpointKey: "instructions"
    )
    _ = try await first.respond(to: "Save")

    let model = RecordedLanguageModel(steps: [.response(text: "rebased")])
    let second = try AgentSession(
      model: model,
      instructions: Instructions("New instructions"),
      checkpointStore: store,
      checkpointKey: "instructions"
    )
    _ = try await second.respond(to: "Restore")

    let transcript = try #require(model.recorder.capturedTranscripts().first)
    let instructionText = transcript.compactMap { entry -> String? in
      guard case .instructions(let instructions) = entry else { return nil }
      return instructions.segments.compactMap { segment in
        guard case .text(let text) = segment else { return nil }
        return text.content
      }.joined(separator: " ")
    }.joined(separator: " ")
    #expect(instructionText.contains("New instructions"))
    #expect(!instructionText.contains("Old instructions"))
  }

  @Test("Rejects a checkpoint restored with a different toolset")
  func checkpointConfigurationMismatch() async throws {
    let store = InMemoryCheckpointStore()
    let first = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "saved")]),
      checkpointStore: store,
      checkpointKey: "toolset"
    )
    _ = try await first.respond(to: "Save")

    let second = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "unused")]),
      tools: [EchoTool(counter: InvocationCounter())],
      checkpointStore: store,
      checkpointKey: "toolset"
    )

    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await second.respond(to: "Restore")
    }
  }

  @Test("File checkpoints encode and decode native transcripts")
  func fileCheckpointRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileCheckpointStore(directory: directory)
    let checkpoint = FoundationModelsAgentCheckpoint(
      compatibilityRevision: "revision",
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "persisted"))]))
      ])
    )

    try await store.saveCheckpoint(checkpoint, for: "../../unsafe-key")
    let restored = try #require(try await store.loadCheckpoint(for: "../../unsafe-key"))

    #expect(restored.compatibilityRevision == "revision")
    #expect(restored.transcript == checkpoint.transcript)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
  }

  @Test("File checkpoints migrate the previous filename")
  func fileCheckpointLegacyFilenameMigration() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileCheckpointStore(directory: directory)
    let checkpoint = FoundationModelsAgentCheckpoint(
      compatibilityRevision: "revision",
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "persisted"))]))
      ])
    )
    let key = "conversation"

    try await store.saveCheckpoint(checkpoint, for: key)
    let currentURL = try #require(
      FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      ).first
    )
    let digest = try #require(currentURL.lastPathComponent.split(separator: ".").first)
    let legacyURL = directory.appending(
      path: "\(digest).\(["core", "agent-transcript.json"].joined())",
      directoryHint: .notDirectory
    )
    try FileManager.default.moveItem(at: currentURL, to: legacyURL)

    let restored = try #require(try await store.loadCheckpoint(for: key))

    #expect(restored.transcript == checkpoint.transcript)
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appending(
          path: "\(digest).foundationmodelsagent-transcript.json",
          directoryHint: .notDirectory
        ).path
      )
    )
  }

  @Test("File checkpoints fall back to a valid previous file")
  func fileCheckpointPreviousFilenameFallback() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileCheckpointStore(directory: directory)
    let checkpoint = FoundationModelsAgentCheckpoint(
      compatibilityRevision: "revision",
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "persisted"))]))
      ])
    )
    let key = "conversation"

    try await store.saveCheckpoint(checkpoint, for: key)
    let currentURL = try #require(
      FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      ).first
    )
    let digest = try #require(currentURL.lastPathComponent.split(separator: ".").first)
    let legacyURL = directory.appending(
      path: "\(digest).\(["core", "agent-transcript.json"].joined())",
      directoryHint: .notDirectory
    )
    try FileManager.default.copyItem(at: currentURL, to: legacyURL)
    try Data("invalid".utf8).write(to: currentURL, options: .atomic)

    let restored = try #require(try await store.loadCheckpoint(for: key))

    #expect(restored.transcript == checkpoint.transcript)
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(try Data(contentsOf: currentURL) != Data("invalid".utf8))
  }

  @Test("File checkpoints reject typed metadata instead of silently erasing its type")
  func fileCheckpointRejectsLossyMetadata() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileCheckpointStore(directory: directory)
    let checkpoint = FoundationModelsAgentCheckpoint(
      compatibilityRevision: "revision",
      transcript: Transcript(entries: [
        .prompt(
          .init(
            metadata: ["provider_flag": true],
            segments: [.text(.init(content: "typed metadata"))]
          )
        )
      ])
    )

    await #expect(throws: FoundationModelsAgentCheckpointStoreError.self) {
      try await store.saveCheckpoint(checkpoint, for: "lossy")
    }
  }

  @Test("File checkpoints reject custom segments without a rehydration codec")
  func fileCheckpointRejectsCustomSegments() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileCheckpointStore(directory: directory)
    let custom = TestCustomSegment(
      id: "video",
      content: .init(value: "provider-specific")
    )
    let checkpoint = FoundationModelsAgentCheckpoint(
      compatibilityRevision: "revision",
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.custom(custom)]))
      ])
    )

    await #expect(throws: FoundationModelsAgentCheckpointStoreError.self) {
      try await store.saveCheckpoint(checkpoint, for: "custom")
    }
  }

  @Test("Checkpoint failures are recorded without turning a completed side effect into a retry")
  func checkpointFailureRecordsAndContinues() async throws {
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "completed")]),
      checkpointStore: FailingCheckpointStore()
    )

    let response = try await session.respond(to: "Complete")

    #expect(response.content == "completed")
    #expect(response.run.events.contains { $0.kind == .transcriptCheckpointFailed })
    #expect(response.run.events.last?.kind == .runCompleted)
  }

  @Test("Skips automatic retention work when no checkpoint store is configured")
  func disabledPersistenceSkipsRetention() async throws {
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "completed")]),
      configuration: .init(checkpointFailurePolicy: .failRun),
      transcriptRetention: .custom { _ in
        throw RetentionError.shouldNotRunAutomatically
      }
    )

    let response = try await session.respond(to: "Complete without persistence")

    #expect(response.content == "completed")
    #expect(!response.run.events.contains { $0.kind == .transcriptCheckpointFailed })
    await #expect(throws: RetentionError.self) {
      _ = try await session.checkpoint()
    }
  }

  @Test("Receipt verification detects tampering")
  func receiptTampering() async throws {
    let response = try await AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "ok")])
    ).respond(to: "Receipt")
    let valid = try FoundationModelsAgentRunReceipt(run: response.run)
    let first = try #require(valid.receipts.first)
    let changedEvent = FoundationModelsAgentEvent(
      id: first.event.id,
      runID: first.event.runID,
      timestamp: first.event.timestamp,
      kind: first.event.kind,
      message: "tampered",
      attributes: first.event.attributes
    )
    var changedReceipts = valid.receipts
    changedReceipts[0] = FoundationModelsAgentEventReceipt(
      index: first.index,
      previousHash: first.previousHash,
      hash: first.hash,
      event: changedEvent
    )
    let tampered = FoundationModelsAgentRunReceipt(
      runID: valid.runID,
      receipts: changedReceipts,
      rootHash: valid.rootHash
    )

    #expect(valid.verify())
    #expect(!tampered.verify())

    let changedRunID = FoundationModelsAgentRunReceipt(
      runID: UUID(),
      receipts: valid.receipts,
      rootHash: valid.rootHash
    )
    #expect(!changedRunID.verify())
  }

  @Test("Exported receipts decode and verify with stable date encoding")
  func receiptExportRoundTrip() async throws {
    let response = try await AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "ok")])
    ).respond(to: "Export")
    let exporter = FoundationModelsAgentReceiptExporter()

    let decoded = try exporter.decode(exporter.data(for: response.run))

    #expect(decoded.verify())
  }

  @Test("Redacts common credentials before observers and receipts see them")
  func eventRedaction() async throws {
    let capture = EventCapture()
    let model = RecordedLanguageModel(steps: [.failure("Bearer super-secret-token")])
    let session = try AgentSession(
      model: model,
      observers: [ClosureFoundationModelsAgentObserver { await capture.append($0) }]
    )

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Fail")
    }

    await session.flushObservers()
    let messages = await capture.events.map(\.message).joined(separator: "\n")
    #expect(!messages.contains("super-secret-token"))
    #expect(messages.contains("[REDACTED]"))
  }

  @Test("Bounds a stalled observer and times out flush instead of blocking the runtime")
  func boundedObserverDelivery() async throws {
    let gate = ObserverGate()
    let capture = EventCapture()
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "done")]),
      observers: [
        ClosureFoundationModelsAgentObserver { event in
          await gate.wait()
          await capture.append(event)
        }
      ],
      observerDeliveryConfiguration: .init(
        maximumPendingEvents: 1,
        overflowPolicy: .dropNewest,
        defaultFlushTimeout: .milliseconds(10)
      )
    )

    let response = try await session.respond(to: "Do not wait for the observer")

    let timedOut = await session.flushObservers()
    #expect(timedOut.status == .timedOut)
    #expect(!timedOut.deliveredAllEvents)
    await gate.open()
    let drained = await session.flushObservers(timeout: .seconds(1))
    #expect(drained.status == .drained)
    #expect(drained.cumulativeDroppedEventCount > 0)
    #expect(!drained.deliveredAllEvents)
    #expect(await capture.events.count < response.run.events.count)
  }

  @Test("Reports a cancelled observer flush separately from a timeout")
  func cancelledObserverFlush() async throws {
    let gate = ObserverGate()
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "done")]),
      observers: [ClosureFoundationModelsAgentObserver { _ in await gate.wait() }]
    )
    _ = try await session.respond(to: "Wait")
    let flush = Task { await session.flushObservers(timeout: .seconds(5)) }

    flush.cancel()

    #expect(await flush.value.status == .cancelled)
    await gate.open()
    #expect(await session.flushObservers(timeout: .seconds(1)).deliveredAllEvents)
  }

  @Test("Rejects a reentrant observer flush without deadlocking")
  func reentrantObserverFlush() async throws {
    let reference = SessionReference()
    let results = BooleanCapture()
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "done")]),
      observers: [
        ClosureFoundationModelsAgentObserver { _ in
          guard let session = await reference.get() else { return }
          let flush = await session.flushObservers(timeout: .seconds(1))
          await results.append(flush.status == .reentrant)
        }
      ]
    )
    await reference.set(session)

    _ = try await session.respond(to: "Observe")

    #expect(await session.flushObservers(timeout: .seconds(1)).deliveredAllEvents)
    let values = await results.values
    #expect(!values.isEmpty)
    #expect(values.allSatisfy { $0 })
  }
}

private actor StringCapture {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}
