import Foundation
import FoundationModels
import FoundationModelsAgent
import FoundationModelsAgentTestSupport
import Testing

@Generable
private struct ChildFailureArguments: Sendable {
  let value: String
}

private enum ChildFailureFixture: Error {
  case intentional
}

private struct FailingChildTool: Tool {
  let name = "failing_child_tool"
  let description = "Always fails for a deterministic test."

  @concurrent
  func call(arguments: ChildFailureArguments) async throws -> String {
    throw ChildFailureFixture.intentional
  }
}

private actor ChildSessionCapture {
  private var sessions: [AgentSession] = []

  func append(_ session: AgentSession) {
    sessions.append(session)
  }

  var count: Int {
    sessions.count
  }

  var last: AgentSession? {
    sessions.last
  }
}

private actor ChildToolInvocationCount {
  private(set) var value = 0

  func increment() {
    value += 1
  }
}

private actor ChildResultCapture {
  private var values: [ChildAgentResult] = []

  func append(_ value: ChildAgentResult) {
    values.append(value)
  }

  var results: [ChildAgentResult] { values }
}

private actor RecursiveChildDefinitionBox {
  private var storage: ChildAgentDefinition?

  func set(_ definition: ChildAgentDefinition) {
    storage = definition
  }

  func value() throws -> ChildAgentDefinition {
    guard let storage else {
      throw ChildFailureFixture.intentional
    }
    return storage
  }
}

private struct CapturingChildAgentTool: Tool {
  typealias Arguments = ChildAgentRequest
  typealias Output = ChildAgentResult

  let base: ChildAgentTool
  let capture: ChildResultCapture

  var name: String { base.name }
  var description: String { base.description }

  @concurrent
  func call(arguments: ChildAgentRequest) async throws -> ChildAgentResult {
    let result = try await base.call(arguments: arguments)
    await capture.append(result)
    return result
  }
}

private struct CountedChildTool: Tool {
  let counter: ChildToolInvocationCount
  let name = "counted_child_tool"
  let description = "Records whether the child tool implementation ran."

  @concurrent
  func call(arguments: ChildFailureArguments) async throws -> String {
    await counter.increment()
    return arguments.value
  }
}

private struct RecordedChildProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Answer only the delegated task.")
    }
    .model(model)
  }
}

private struct RecordedToolChildProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel
  let tool: CountedChildTool

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Use the counted child tool.")
      tool
    }
    .model(model)
  }
}

@Suite("Foreground child agents")
struct ChildAgentToolTests {
  @Test("Returns a bounded structured success from a fresh child session")
  func success() async throws {
    let definition = try ChildAgentDefinition(
      identifier: "research_child",
      description: "Consult a focused research child."
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "child finding")])
      )
    }
    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Investigate this.")
    )

    #expect(result.identifier == "research_child")
    #expect(result.status == .succeeded)
    #expect(result.content == "child finding")
    #expect(result.taskResult.failureReason == nil)
    #expect(result.turnsUsed == 1)
    #expect(!result.wasTruncated)
    let decoded = try JSONDecoder().decode(
      ChildAgentResult.self,
      from: JSONEncoder().encode(result)
    )
    #expect(decoded == result)
  }

  @Test("Returns child tool failure as a structured model-safe result")
  func toolFailure() async throws {
    let definition = try ChildAgentDefinition(
      identifier: "failing_child",
      description: "Exercise a failing child tool."
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [
          .toolCall(
            name: "failing_child_tool",
            argumentsJSON: #"{"value":"fail"}"#
          )
        ]),
        tools: [FailingChildTool()]
      )
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Use the failing tool.")
    )

    #expect(result.status == .failed)
    #expect(result.taskResult.failureReason?.code == "child_failure")
    #expect(result.content == nil)
  }

  @Test("Returns cancellation structurally and cancels the child response")
  func cancellation() async throws {
    let capture = ChildSessionCapture()
    let model = RecordedLanguageModel(steps: [
      .delayedResponse(text: "too late", delay: .seconds(1))
    ])
    let definition = try ChildAgentDefinition(
      identifier: "slow_child",
      description: "Waits for cancellation."
    ) { _ in
      let session = try AgentSession(model: model)
      await capture.append(session)
      return session
    }
    let consultation = Task {
      try await ChildAgentTool(definition: definition).call(
        arguments: ChildAgentRequest(task: "Wait.")
      )
    }
    while model.recorder.capturedTranscripts().isEmpty {
      await Task.yield()
    }

    consultation.cancel()
    let result = try await consultation.value

    #expect(result.status == .cancelled)
    #expect(result.taskResult.cancellationReason?.code == "child_cancelled")
    let child = try #require(await capture.last)
    let run = try #require(await child.lastRun())
    #expect(run.events.last?.kind == .runCancelled)
  }

  @Test("Applies a wall-clock timeout to the whole child consultation")
  func timeout() async throws {
    let definition = try ChildAgentDefinition(
      identifier: "timed_child",
      description: "Exceeds its consultation deadline.",
      limits: ChildAgentLimits(wallClockTimeout: .milliseconds(10))
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [
          .delayedResponse(text: "too late", delay: .seconds(1))
        ])
      )
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Take too long.")
    )

    #expect(result.status == .timedOut)
    #expect(result.taskResult.failureReason?.code == "wall_clock_timeout")
  }

  @Test("Parent cancellation cascades through the foreground child")
  func parentCancellationCascades() async throws {
    let capture = ChildSessionCapture()
    let childModel = RecordedLanguageModel(steps: [
      .delayedResponse(text: "too late", delay: .seconds(1))
    ])
    let childDefinition = try ChildAgentDefinition(
      identifier: "cancelled_child",
      description: "Stops when its parent stops."
    ) { _ in
      let session = try AgentSession(model: childModel)
      await capture.append(session)
      return session
    }
    let parent = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(
          name: "cancelled_child",
          argumentsJSON: #"{"task":"Wait for cancellation."}"#
        )
      ]),
      tools: [ChildAgentTool(definition: childDefinition)]
    )
    let parentRun = Task {
      try await parent.respond(to: "Consult the child.")
    }
    while childModel.recorder.capturedTranscripts().isEmpty {
      await Task.yield()
    }

    parentRun.cancel()

    await #expect(throws: (any Error).self) {
      _ = try await parentRun.value
    }
    let child = try #require(await capture.last)
    let childRun = try #require(await child.lastRun())
    #expect(childRun.events.last?.kind == .runCancelled)
  }

  @Test("Rejects a consultation at the configured depth boundary")
  func depthRejection() async throws {
    let capture = ChildSessionCapture()
    let definition = try ChildAgentDefinition(
      identifier: "depth_limited_child",
      description: "Cannot be entered at this depth.",
      limits: ChildAgentLimits(maximumDepth: 0)
    ) { _ in
      let session = try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "must not run")])
      )
      await capture.append(session)
      return session
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Recurse.")
    )

    #expect(result.status == .failed)
    #expect(result.taskResult.failureReason?.code == "depth_limit_exceeded")
    #expect(await capture.count == 0)
  }

  @Test("Carries depth through nested native child tool calls")
  func recursiveDepthRejection() async throws {
    let nestedCapture = ChildSessionCapture()
    let nestedDefinition = try ChildAgentDefinition(
      identifier: "nested_child",
      description: "Cannot widen its inherited depth budget.",
      limits: ChildAgentLimits(maximumDepth: 10)
    ) { _ in
      let session = try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "must not run")])
      )
      await nestedCapture.append(session)
      return session
    }
    let outerModel = RecordedLanguageModel(steps: [
      .toolCall(
        name: "nested_child",
        argumentsJSON: #"{"task":"Try a nested consultation."}"#
      ),
      .response(text: "nested rejection handled"),
    ])
    let outerDefinition = try ChildAgentDefinition(
      identifier: "outer_child",
      description: "Attempts a nested consultation.",
      limits: ChildAgentLimits(maximumDepth: 1)
    ) { _ in
      try AgentSession(
        model: outerModel,
        tools: [ChildAgentTool(definition: nestedDefinition)]
      )
    }

    let result = try await ChildAgentTool(definition: outerDefinition).call(
      arguments: ChildAgentRequest(task: "Consult another child.")
    )

    #expect(result.status == .succeeded)
    #expect(result.content == "nested rejection handled")
    #expect(await nestedCapture.count == 0)
  }

  @Test("Recursive self-delegation cannot widen its canonical depth")
  func recursiveSelfDelegation() async throws {
    let box = RecursiveChildDefinitionBox()
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        name: "self_child",
        argumentsJSON: #"{"task":"Delegate to yourself."}"#
      ),
      .response(text: "self-delegation rejected"),
    ])
    let definition = try ChildAgentDefinition(
      identifier: "self_child",
      description: "Attempts to call itself.",
      limits: ChildAgentLimits(maximumDepth: 1)
    ) { _ in
      let recursiveDefinition = try await box.value()
      return try AgentSession(
        model: model,
        tools: [ChildAgentTool(definition: recursiveDefinition)]
      )
    }
    await box.set(definition)

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Start recursion.")
    )

    #expect(result.status == .succeeded)
    #expect(result.content == "self-delegation rejected")
    #expect(model.recorder.capturedTranscripts().count == 2)
  }

  @Test("Rejects a consultation when no child turn is permitted")
  func turnRejection() async throws {
    let capture = ChildSessionCapture()
    let definition = try ChildAgentDefinition(
      identifier: "turn_limited_child",
      description: "Has no available foreground turn.",
      limits: ChildAgentLimits(maximumTurns: 0)
    ) { _ in
      let session = try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "must not run")])
      )
      await capture.append(session)
      return session
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Use a turn.")
    )

    #expect(result.status == .failed)
    #expect(result.taskResult.failureReason?.code == "turn_limit_exceeded")
    #expect(await capture.count == 0)
  }

  @Test("Uses an independent native transcript for every invocation")
  func isolatedHistory() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(text: "first child answer"),
      .response(text: "second child answer"),
    ])
    let capture = ChildSessionCapture()
    let definition = try ChildAgentDefinition(
      identifier: "isolated_child",
      description: "Starts with isolated native history."
    ) { _ in
      let session = try AgentSession(model: model)
      await capture.append(session)
      return session
    }
    let tool = ChildAgentTool(definition: definition)

    _ = try await tool.call(arguments: ChildAgentRequest(task: "First task."))
    _ = try await tool.call(arguments: ChildAgentRequest(task: "Second task."))

    #expect(await capture.count == 2)
    let transcripts = model.recorder.capturedTranscripts()
    #expect(transcripts.count == 2)
    #expect(
      transcripts.allSatisfy { transcript in
        transcript.filter { entry in
          if case .prompt = entry { return true }
          return false
        }.count == 1
      })
    #expect(
      transcripts.allSatisfy { transcript in
        !transcript.contains { entry in
          if case .response = entry { return true }
          return false
        }
      })
  }

  @Test("Bounds successful output without splitting a grapheme")
  func outputBounding() async throws {
    let definition = try ChildAgentDefinition(
      identifier: "bounded_child",
      description: "Returns bounded findings.",
      limits: ChildAgentLimits(maximumOutputBytes: 3)
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "é🙂tail")])
      )
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Return Unicode.")
    )

    #expect(result.status == .succeeded)
    #expect(result.content == "é")
    #expect(result.content?.utf8.count == 2)
    #expect(result.wasTruncated)
  }

  @Test("The parent model remains responsible for the final answer")
  func parentFinalAnswer() async throws {
    let childDefinition = try ChildAgentDefinition(
      identifier: "phone_a_friend",
      description: "Consult a child, then use its result when answering."
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "private child finding")])
      )
    }
    let parentModel = RecordedLanguageModel(steps: [
      .toolCall(
        name: "phone_a_friend",
        argumentsJSON: #"{"task":"Check the detail."}"#
      ),
      .response(text: "parent-authored final answer"),
    ])
    let parent = try AgentSession(
      model: parentModel,
      tools: [ChildAgentTool(definition: childDefinition)]
    )

    let response = try await parent.respond(to: "Give me the final answer.")

    #expect(response.content == "parent-authored final answer")
    #expect(response.content != "private child finding")
    #expect(parentModel.recorder.capturedTranscripts().count == 2)
  }

  @Test("Enforces the child tool-call budget before implementation")
  func toolCallLimit() async throws {
    let counter = ChildToolInvocationCount()
    let definition = try ChildAgentDefinition(
      identifier: "tool_limited_child",
      description: "Cannot call native child tools.",
      limits: ChildAgentLimits(maximumToolCalls: 0)
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [
          .toolCall(
            name: "counted_child_tool",
            argumentsJSON: #"{"value":"blocked"}"#
          )
        ]),
        tools: [CountedChildTool(counter: counter)]
      )
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Try the tool.")
    )

    #expect(result.status == .failed)
    #expect(result.taskResult.failureReason?.code == "tool_call_limit_exceeded")
    #expect(await counter.value == 0)
  }

  @Test("Creates a fresh dynamic-profile child session")
  func dynamicProfileFactory() async throws {
    let model = RecordedLanguageModel(steps: [.response(text: "profile child answer")])
    let definition = try ChildAgentDefinition(
      identifier: "profile_child",
      description: "Uses a native dynamic profile."
    ) { _ in
      RecordedChildProfile(model: model)
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Use the profile.")
    )

    #expect(result.status == .succeeded)
    #expect(result.content == "profile child answer")
    #expect(model.recorder.capturedTranscripts().count == 1)
  }

  @Test("Enforces child tool-call limits for dynamic profiles")
  func dynamicProfileToolCallLimit() async throws {
    let counter = ChildToolInvocationCount()
    let childTool = CountedChildTool(counter: counter)
    let registry = try DynamicProfileToolRegistry(tools: [childTool])
    let governance = try DynamicProfileToolGovernanceConfiguration(trusting: registry)
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        name: "counted_child_tool",
        argumentsJSON: #"{"value":"blocked"}"#
      )
    ])
    let definition = try ChildAgentDefinition(
      identifier: "limited_profile_child",
      description: "Uses a tool-limited native dynamic profile.",
      limits: ChildAgentLimits(maximumToolCalls: 0),
      toolGovernance: governance
    ) { _ in
      RecordedToolChildProfile(
        model: model,
        tool: childTool
      )
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Try the profile tool.")
    )

    #expect(result.status == .failed)
    #expect(result.taskResult.failureReason?.code == "tool_call_limit_exceeded")
    #expect(await counter.value == 0)
  }

  @Test("Returns policy denial without constructing a child session")
  func policyDenial() async throws {
    let capture = ChildSessionCapture()
    let definition = try ChildAgentDefinition(
      identifier: "policy_child",
      description: "Requires an explicit delegation decision.",
      policy: ClosureChildAgentPolicy { _ in
        .deny(reason: "Parent denial must be inherited.")
      }
    ) { _ in
      let session = try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "must not run")])
      )
      await capture.append(session)
      return session
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Attempt delegation.")
    )

    #expect(result.status == .denied)
    #expect(result.taskResult.failureReason?.code == "policy_denied")
    #expect(result.taskResult.failureReason?.message == "Parent denial must be inherited.")
    #expect(await capture.count == 0)
  }

  @Test("Bounds policy denial details before returning them to the parent")
  func failureBounding() async throws {
    let definition = try ChildAgentDefinition(
      identifier: "bounded_failure_child",
      description: "Bounds a model-visible policy reason.",
      limits: ChildAgentLimits(maximumFailureBytes: 3),
      policy: ClosureChildAgentPolicy { _ in
        .deny(reason: "abcdef")
      }
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "must not run")])
      )
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Attempt delegation.")
    )

    #expect(result.status == .denied)
    #expect(result.taskResult.failureReason?.message == "abc")
    #expect(result.wasTruncated)
  }

  @Test("Maps malformed or failed child generation without leaking its text")
  func malformedChildOutput() async throws {
    let definition = try ChildAgentDefinition(
      identifier: "malformed_child",
      description: "Returns a structured failure for malformed generation."
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [.failure("secret malformed payload")])
      )
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Produce malformed output.")
    )

    #expect(result.status == .failed)
    #expect(result.taskResult.failureReason?.code == "child_failure")
    #expect(result.taskResult.failureReason?.message == "The child-agent consultation failed.")
    #expect(result.content == nil)
  }

  @Test("Redacts sensitive child content before bounding and model projection")
  func sensitiveOutputRedaction() async throws {
    let definition = try ChildAgentDefinition(
      identifier: "redacting_child",
      description: "Redacts sensitive findings."
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "token=super-secret")])
      )
    }

    let result = try await ChildAgentTool(definition: definition).call(
      arguments: ChildAgentRequest(task: "Return a sensitive value.")
    )

    #expect(result.content == "token=[REDACTED]")
    #expect(!String(describing: result.promptRepresentation).contains("super-secret"))
  }

  @Test("Concurrent calls create fresh sessions and distinct canonical tasks")
  func concurrentChildren() async throws {
    let capture = ChildSessionCapture()
    let model = RecordedLanguageModel(steps: [
      .response(text: "first"),
      .response(text: "second"),
    ])
    let definition = try ChildAgentDefinition(
      identifier: "concurrent_child",
      description: "Runs independent consultations."
    ) { _ in
      let session = try AgentSession(model: model)
      await capture.append(session)
      return session
    }
    let tool = ChildAgentTool(definition: definition)

    async let first = tool.call(arguments: ChildAgentRequest(task: "First."))
    async let second = tool.call(arguments: ChildAgentRequest(task: "Second."))
    let results = try await [first, second]

    #expect(results.allSatisfy { $0.status == .succeeded })
    #expect(Set(results.map(\.taskResult.lineage.runID)).count == 2)
    #expect(Set(results.compactMap(\.taskResult.lineage.taskID)).count == 2)
    #expect(await capture.count == 2)
  }

  @Test("Parent timeout cancels an in-flight foreground child")
  func parentTimeoutCascades() async throws {
    let capture = ChildSessionCapture()
    let childModel = RecordedLanguageModel(steps: [
      .delayedResponse(text: "late", delay: .seconds(1))
    ])
    let definition = try ChildAgentDefinition(
      identifier: "parent_timeout_child",
      description: "Is cancelled by the parent deadline.",
      limits: ChildAgentLimits(wallClockTimeout: .seconds(5))
    ) { _ in
      let session = try AgentSession(model: childModel)
      await capture.append(session)
      return session
    }
    let parent = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(
          name: "parent_timeout_child",
          argumentsJSON: #"{"task":"Wait."}"#
        )
      ]),
      tools: [ChildAgentTool(definition: definition)],
      configuration: FoundationModelsAgentConfiguration(
        responseTimeout: .milliseconds(10)
      )
    )

    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await parent.respond(to: "Consult.")
    }
    let child = try #require(await capture.last)
    let run = try #require(await child.lastRun())
    #expect(run.events.last?.kind == .runCancelled)
  }

  @Test("Child count is enforced per tool in one parent run")
  func childCountLimit() async throws {
    let capture = ChildSessionCapture()
    let childModel = RecordedLanguageModel(steps: [
      .response(text: "one"),
      .response(text: "two"),
    ])
    let definition = try ChildAgentDefinition(
      identifier: "count_limited_child",
      description: "Allows two consultations.",
      limits: ChildAgentLimits(maximumChildrenPerParentRun: 2)
    ) { _ in
      let session = try AgentSession(model: childModel)
      await capture.append(session)
      return session
    }
    let resultCapture = ChildResultCapture()
    let parent = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(name: "count_limited_child", argumentsJSON: #"{"task":"One."}"#),
        .toolCall(name: "count_limited_child", argumentsJSON: #"{"task":"Two."}"#),
        .toolCall(name: "count_limited_child", argumentsJSON: #"{"task":"Three."}"#),
        .response(text: "parent done"),
      ]),
      tools: [
        CapturingChildAgentTool(
          base: ChildAgentTool(definition: definition),
          capture: resultCapture
        )
      ]
    )

    _ = try await parent.respond(to: "Consult three times.")
    let results = await resultCapture.results
    #expect(results.map(\.status) == [.succeeded, .succeeded, .failed])
    #expect(results.last?.taskResult.failureReason?.code == "child_limit_exceeded")
    #expect(await capture.count == 2)
  }

  @Test("Child result, run, receipt, and parent share canonical lineage")
  func canonicalLineageAndReceipt() async throws {
    let capture = ChildResultCapture()
    let definition = try ChildAgentDefinition(
      identifier: "lineage_child",
      description: "Produces canonical child evidence."
    ) { _ in
      try AgentSession(model: RecordedLanguageModel(steps: [.response(text: "evidence")]))
    }
    let parent = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(name: "lineage_child", argumentsJSON: #"{"task":"Investigate."}"#),
        .response(text: "parent answer"),
      ]),
      tools: [
        CapturingChildAgentTool(
          base: ChildAgentTool(definition: definition),
          capture: capture
        )
      ]
    )

    let parentResponse = try await parent.respond(to: "Use evidence.")
    let childResult = try #require(await capture.results.first)
    let childReceipt = try #require(childResult.receipt)
    let parentReceipt = try FoundationModelsAgentRunReceipt(run: parentResponse.run)
    let parentLineage = try #require(parentResponse.run.lineage)
    let childLineage = childResult.taskResult.lineage

    #expect(childLineage.parentRunID == parentLineage.runID)
    #expect(childLineage.rootRunID == parentLineage.rootRunID)
    #expect(childReceipt.lineage == childLineage)
    let bundle = AgentReceiptBundle(
      receipts: [parentReceipt, childReceipt],
      taskResults: [childResult.taskResult]
    )
    try bundle.verify(maximumDepth: AgentRunDepth(1))
  }
}
