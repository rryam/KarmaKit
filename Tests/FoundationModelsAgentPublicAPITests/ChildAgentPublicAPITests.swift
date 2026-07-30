import Foundation
import FoundationModels
import FoundationModelsAgent
import FoundationModelsAgentTestSupport
import Testing

private actor PublicChildResultCapture {
  private var storage: [ChildAgentResult] = []

  func append(_ result: ChildAgentResult) {
    storage.append(result)
  }

  var results: [ChildAgentResult] { storage }
}

private final class PublicChildInstrumentationCapture: AgentSessionInstrumentationSink,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storage: [AgentSessionInstrumentationEvent] = []

  func receive(_ event: AgentSessionInstrumentationEvent) {
    lock.withLock {
      storage.append(event)
    }
  }

  var events: [AgentSessionInstrumentationEvent] {
    lock.withLock { storage }
  }
}

private struct PublicCapturingChildTool: Tool {
  typealias Arguments = ChildAgentRequest
  typealias Output = ChildAgentResult

  let child: ChildAgentTool
  let capture: PublicChildResultCapture

  var name: String { child.name }
  var description: String { child.description }

  @concurrent
  func call(arguments: ChildAgentRequest) async throws -> ChildAgentResult {
    let result = try await child.call(arguments: arguments)
    await capture.append(result)
    return result
  }
}

private struct PublicRecordedProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Answer only the delegated task.")
    }
    .model(model)
  }
}

@Suite("Child-agent public API consumer")
struct ChildAgentPublicAPITests {
  @Test("Explicit-model and dynamic-profile factories are ergonomic and fresh")
  func publicFactories() async throws {
    let explicitModel = RecordedLanguageModel(steps: [
      .response(text: "explicit one"),
      .response(text: "explicit two"),
    ])
    let explicit = try ChildAgentDefinition(
      identifier: "explicit_specialist",
      description: "Consult an explicit-model specialist."
    ) { invocation in
      #expect(invocation.lineage.relationship == .child)
      return try AgentSession(
        model: explicitModel,
        instructions: Instructions("Handle \(invocation.task)")
      )
    }
    let explicitTool = ChildAgentTool(definition: explicit)
    let first = try await explicitTool.call(
      arguments: ChildAgentRequest(task: "First.")
    )
    let second = try await explicitTool.call(
      arguments: ChildAgentRequest(task: "Second.")
    )

    #expect(first.status == .succeeded)
    #expect(second.status == .succeeded)
    #expect(first.taskResult.lineage.runID != second.taskResult.lineage.runID)
    #expect(explicitModel.recorder.capturedTranscripts().count == 2)

    let profileModel = RecordedLanguageModel(steps: [.response(text: "profile")])
    let profile = try ChildAgentDefinition(
      identifier: "profile_specialist",
      description: "Consult a native dynamic-profile specialist."
    ) { _ in
      PublicRecordedProfile(model: profileModel)
    }
    let profileResult = try await ChildAgentTool(definition: profile).call(
      arguments: ChildAgentRequest(task: "Profile task.")
    )

    #expect(profileResult.status == .succeeded)
    #expect(profileResult.content == "profile")
  }

  @Test("One-turn, depth, child, time, tool, and output limits settle structurally")
  func publicLimits() async throws {
    let noTurn = try ChildAgentDefinition(
      identifier: "no_turn",
      description: "Has no child turn.",
      limits: ChildAgentLimits(maximumTurns: 0)
    ) { _ in
      try AgentSession(model: RecordedLanguageModel(steps: [.response(text: "unused")]))
    }
    let turnResult = try await ChildAgentTool(definition: noTurn).call(
      arguments: ChildAgentRequest(task: "Rejected.")
    )
    #expect(turnResult.taskResult.failureReason?.code == "turn_limit_exceeded")
    let rootLineage = AgentRunLineage.root(
      runID: turnResult.taskResult.lineage.rootRunID)
    let rootRun = FoundationModelsAgentRun(
      id: rootLineage.runID.rawValue,
      startedAt: turnResult.taskResult.timing.startedAt,
      endedAt: turnResult.taskResult.timing.endedAt,
      usage: nil,
      events: [],
      lineage: rootLineage
    )
    let preflightBundle = AgentReceiptBundle(
      receipts: [
        try FoundationModelsAgentRunReceipt(run: rootRun),
        try #require(turnResult.receipt),
      ],
      taskResults: [turnResult.taskResult]
    )
    try preflightBundle.verify(maximumDepth: AgentRunDepth(1))

    let noDepth = try ChildAgentDefinition(
      identifier: "no_depth",
      description: "Has no child depth.",
      limits: ChildAgentLimits(maximumDepth: 0)
    ) { _ in
      try AgentSession(model: RecordedLanguageModel(steps: [.response(text: "unused")]))
    }
    let depthResult = try await ChildAgentTool(definition: noDepth).call(
      arguments: ChildAgentRequest(task: "Rejected.")
    )
    #expect(depthResult.taskResult.failureReason?.code == "depth_limit_exceeded")

    let noTime = try ChildAgentDefinition(
      identifier: "no_time",
      description: "Has no wall-clock time.",
      limits: ChildAgentLimits(wallClockTimeout: .zero)
    ) { _ in
      try AgentSession(model: RecordedLanguageModel(steps: [.response(text: "unused")]))
    }
    let timedResult = try await ChildAgentTool(definition: noTime).call(
      arguments: ChildAgentRequest(task: "Rejected.")
    )
    #expect(timedResult.status == .timedOut)

    let bounded = try ChildAgentDefinition(
      identifier: "bounded",
      description: "Bounds output.",
      limits: ChildAgentLimits(maximumOutputBytes: 2)
    ) { _ in
      try AgentSession(model: RecordedLanguageModel(steps: [.response(text: "é-more")]))
    }
    let boundedResult = try await ChildAgentTool(definition: bounded).call(
      arguments: ChildAgentRequest(task: "Bound.")
    )
    #expect(boundedResult.content == "é")
    #expect(boundedResult.wasTruncated)
    #expect(boundedResult.turnsUsed == 1)
  }

  @Test("A realistic parent consults specialists and owns the final answer")
  func multipleSpecialistsAndCanonicalEvidence() async throws {
    let capture = PublicChildResultCapture()
    let instrumentation = PublicChildInstrumentationCapture()
    let instrumentationConfiguration = AgentSessionInstrumentationConfiguration(
      correlationMetadata: ["scenario": "multiple-specialists"],
      sink: instrumentation
    )
    let research = try ChildAgentDefinition(
      identifier: "research_specialist",
      description: "Research a focused fact."
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "fact")]),
        instrumentation: instrumentationConfiguration
      )
    }
    let review = try ChildAgentDefinition(
      identifier: "review_specialist",
      description: "Review a focused claim."
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "review")]),
        instrumentation: instrumentationConfiguration
      )
    }
    let parent = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(name: "research_specialist", argumentsJSON: #"{"task":"Research."}"#),
        .toolCall(name: "review_specialist", argumentsJSON: #"{"task":"Review."}"#),
        .response(text: "parent final answer"),
      ]),
      tools: [
        PublicCapturingChildTool(
          child: ChildAgentTool(definition: research),
          capture: capture
        ),
        PublicCapturingChildTool(
          child: ChildAgentTool(definition: review),
          capture: capture
        ),
      ],
      instrumentation: instrumentationConfiguration
    )

    let response = try await parent.respond(to: "Use both specialists.")
    let results = await capture.results
    #expect(response.content == "parent final answer")
    #expect(results.count == 2)
    let parentLineage = try #require(response.run.lineage)
    #expect(
      results.allSatisfy { result in
        result.taskResult.lineage.parentRunID == parentLineage.runID
          && result.taskResult.lineage.rootRunID == parentLineage.rootRunID
          && result.receipt?.lineage == result.taskResult.lineage
      })
    let childRunIDs = Set(results.map { $0.taskResult.lineage.runID.description })
    #expect(
      instrumentation.events.contains { event in
        childRunIDs.contains(event.correlationMetadata["run_id"] ?? "")
          && event.correlationMetadata["parent_run_id"] == parentLineage.runID.description
          && event.correlationMetadata["scenario"] == "multiple-specialists"
      })

    let parentReceipt = try FoundationModelsAgentRunReceipt(run: response.run)
    let bundle = AgentReceiptBundle(
      receipts: [parentReceipt] + results.compactMap(\.receipt),
      taskResults: results.map(\.taskResult)
    )
    try bundle.verify(maximumDepth: AgentRunDepth(1))
  }

  @Test("Concurrent children are isolated and sensitive output is redacted")
  func concurrentIsolationAndRedaction() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(text: "token=first-secret"),
      .response(text: "token=second-secret"),
    ])
    let definition = try ChildAgentDefinition(
      identifier: "isolated_redacting_child",
      description: "Creates a fresh redacting child."
    ) { _ in
      try AgentSession(model: model)
    }
    let tool = ChildAgentTool(definition: definition)

    async let first = tool.call(arguments: ChildAgentRequest(task: "First."))
    async let second = tool.call(arguments: ChildAgentRequest(task: "Second."))
    let results = try await [first, second]

    #expect(results.allSatisfy { $0.content == "token=[REDACTED]" })
    #expect(Set(results.map(\.taskResult.lineage.runID)).count == 2)
    #expect(
      model.recorder.capturedTranscripts().allSatisfy { transcript in
        transcript.history.filter {
          if case .prompt = $0 { return true }
          return false
        }.count == 1
      })
  }

  @Test("Denied and malformed child work maps to canonical settlements")
  func publicFailureMapping() async throws {
    let denied = try ChildAgentDefinition(
      identifier: "denied_child",
      description: "Is denied before construction.",
      policy: ClosureChildAgentPolicy { _ in
        .deny(reason: "secret=do-not-leak")
      }
    ) { _ in
      try AgentSession(model: RecordedLanguageModel(steps: [.response(text: "unused")]))
    }
    let denial = try await ChildAgentTool(definition: denied).call(
      arguments: ChildAgentRequest(task: "Denied.")
    )
    #expect(denial.status == .denied)
    #expect(denial.taskResult.failureReason?.message == "secret=[REDACTED]")

    let malformed = try ChildAgentDefinition(
      identifier: "malformed_child",
      description: "Fails generation."
    ) { _ in
      try AgentSession(model: RecordedLanguageModel(steps: [.failure("malformed secret")]))
    }
    let failure = try await ChildAgentTool(definition: malformed).call(
      arguments: ChildAgentRequest(task: "Fail.")
    )
    #expect(failure.status == .failed)
    #expect(failure.taskResult.failureReason?.code == "child_failure")
    #expect(failure.content == nil)
  }

  @Test("Checkpoint scope stays explicit and child history does not leak across keys")
  func checkpointIsolation() async throws {
    let store = InMemoryCheckpointStore()
    let child = try ChildAgentDefinition(
      identifier: "checkpoint_child",
      description: "Uses an explicitly child-scoped checkpoint."
    ) { _ in
      try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "child checkpoint output")]),
        checkpointStore: store,
        checkpointKey: "child-scope"
      )
    }
    let capture = PublicChildResultCapture()
    let parent = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(name: "checkpoint_child", argumentsJSON: #"{"task":"Child-only task."}"#),
        .response(text: "parent output"),
      ]),
      tools: [
        PublicCapturingChildTool(
          child: ChildAgentTool(definition: child),
          capture: capture
        )
      ],
      checkpointStore: store,
      checkpointKey: "parent-scope"
    )

    _ = try await parent.respond(to: "Parent-only task.")
    let parentCheckpoint = try #require(await store.loadCheckpoint(for: "parent-scope"))
    let childCheckpoint = try #require(await store.loadCheckpoint(for: "child-scope"))
    #expect(parentCheckpoint.transcript != childCheckpoint.transcript)
    #expect(
      childCheckpoint.transcript.history.filter {
        if case .prompt = $0 { return true }
        return false
      }.count == 1
    )
    let result = try #require(await capture.results.first)
    #expect(result.receipt?.lineage == result.taskResult.lineage)
  }
}
