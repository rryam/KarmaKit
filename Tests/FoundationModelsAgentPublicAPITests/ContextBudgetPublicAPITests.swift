import Foundation
import FoundationModels
import FoundationModelsAgent
import FoundationModelsAgentTestSupport
import Testing

@Generable
private struct PublicBudgetAnswer: Sendable {
  let value: String
}

@Generable
private struct PublicBudgetArguments: Sendable {
  let value: String
}

private struct PublicBudgetTool: Tool {
  let name = "public_budget_tool"
  let description = "Returns the supplied value."

  @concurrent
  func call(arguments: PublicBudgetArguments) async throws -> String {
    arguments.value
  }
}

private struct PublicBudgetProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Opaque profile instructions.")
    }
    .model(model)
  }
}

private enum PublicMeasurementError: Error {
  case unavailable
}

private final class PublicLockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) {
    storage = value
  }

  func withLock<Result>(_ operation: (inout Value) -> Result) -> Result {
    lock.withLock {
      operation(&storage)
    }
  }

  var value: Value {
    lock.withLock { storage }
  }
}

private actor PublicProbe {
  private(set) var measurements: [AgentSessionContextMeasurementRequest] = []
  private(set) var partialCount = 0

  func record(_ request: AgentSessionContextMeasurementRequest) {
    measurements.append(request)
  }

  func recordPartial() {
    partialCount += 1
  }
}

private func publicCounts(
  contextSize: Int,
  instructions: Int = 0,
  tools: Int = 0,
  prompt: Int = 1,
  schema: Int = 0,
  transcript: Int = 0
) -> AgentSessionContextTokenCounts {
  AgentSessionContextTokenCounts(
    contextSize: contextSize,
    instructions: instructions,
    tools: tools,
    prompt: prompt,
    schema: schema,
    transcript: transcript
  )
}

private func publicCandidate(
  id: String,
  model: RecordedLanguageModel,
  declaredContext: Int
) -> FoundationModelsAgentRouteCandidate {
  FoundationModelsAgentRouteCandidate(
    model: model,
    descriptor: FoundationModelsAgentRouteDescriptor(
      id: FoundationModelsAgentRouteID(id),
      purpose: "Public consumer probe.",
      declaredCapabilities: [.guidedGeneration],
      availability: .init(state: .available),
      privacyClass: .onDevice,
      networkClass: .none,
      contextSize: .known(tokenLimit: declaredContext),
      reasoningSupport: .unsupported,
      accountingProvenance: .none
    )
  )
}

@Suite("Context budget public API consumer")
struct ContextBudgetPublicAPITests {
  @Test("Exact limit succeeds while reserved headroom fails before inference")
  func exactLimitAndHeadroom() async throws {
    let exactModel = RecordedLanguageModel(steps: [.response(text: "exact")])
    let exact = try AgentSession(
      model: exactModel,
      configuration: .init(
        contextBudget: .init(reservedResponseTokens: 1)
      ),
      contextMeasurer: AgentSessionContextMeasurer { _, _ in
        publicCounts(contextSize: 10, prompt: 9)
      }
    )
    #expect(try await exact.respond(to: "Exact").content == "exact")

    let overflowModel = RecordedLanguageModel(steps: [.response(text: "unused")])
    let overflow = try AgentSession(
      model: overflowModel,
      configuration: .init(
        contextBudget: .init(reservedResponseTokens: 2)
      ),
      contextMeasurer: AgentSessionContextMeasurer { _, _ in
        publicCounts(contextSize: 10, prompt: 9)
      }
    )
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await overflow.respond(to: "Headroom")
    }
    #expect(overflowModel.recorder.capturedTranscripts().isEmpty)
  }

  @Test("Zero and unavailable context measurements fail honestly")
  func zeroAndUnavailableContext() async throws {
    let zeroModel = RecordedLanguageModel(steps: [.response(text: "unused")])
    let zero = try AgentSession(
      model: zeroModel,
      configuration: .init(
        contextBudget: .init(reservedResponseTokens: 0)
      ),
      contextMeasurer: AgentSessionContextMeasurer { _, _ in
        publicCounts(contextSize: 0)
      }
    )
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await zero.respond(to: "Zero")
    }
    #expect(zeroModel.recorder.capturedTranscripts().isEmpty)

    let unknownModel = RecordedLanguageModel(steps: [.response(text: "unused")])
    let unknown = try AgentSession(
      model: unknownModel,
      configuration: .init(contextBudget: .init()),
      contextMeasurer: AgentSessionContextMeasurer { _, _ in
        throw PublicMeasurementError.unavailable
      }
    )
    await #expect(throws: PublicMeasurementError.self) {
      _ = try await unknown.respond(to: "Unknown")
    }
    let run = try #require(await unknown.lastRun())
    #expect(run.events.contains { $0.kind == .contextBudgetFailed })
    #expect(unknownModel.recorder.capturedTranscripts().isEmpty)
  }

  @Test("Unsupported custom models and invalid limits fail at construction")
  func constructionRejections() {
    #expect(throws: FoundationModelsAgentError.self) {
      _ = try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "unused")]),
        configuration: .init(contextBudget: .init())
      )
    }
    #expect(throws: FoundationModelsAgentError.self) {
      _ = try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "unused")]),
        configuration: .init(
          contextBudget: .init(reservedResponseTokens: -1)
        ),
        contextMeasurer: AgentSessionContextMeasurer { _, _ in
          publicCounts(contextSize: 8)
        }
      )
    }
    #expect(throws: FoundationModelsAgentError.self) {
      _ = try AgentSession(
        model: RecordedLanguageModel(steps: [.response(text: "unused")]),
        configuration: .init(
          contextBudget: .init(maximumUsableFraction: .nan)
        ),
        contextMeasurer: AgentSessionContextMeasurer { _, _ in
          publicCounts(contextSize: 8)
        }
      )
    }
  }

  @Test("Adversarial counts saturate without wrapping or approving")
  func adversarialCounts() async throws {
    let saturatedModel = RecordedLanguageModel(steps: [.response(text: "unused")])
    let saturated = try AgentSession(
      model: saturatedModel,
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          maximumUsableFraction: Double(1).nextDown
        )
      ),
      contextMeasurer: AgentSessionContextMeasurer { _, _ in
        publicCounts(
          contextSize: Int.max,
          instructions: Int.max,
          prompt: Int.max,
          transcript: Int.max
        )
      }
    )
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await saturated.respond(to: "Saturate")
    }
    #expect(saturatedModel.recorder.capturedTranscripts().isEmpty)

    let negativeModel = RecordedLanguageModel(steps: [.response(text: "unused")])
    let negative = try AgentSession(
      model: negativeModel,
      configuration: .init(contextBudget: .init()),
      contextMeasurer: AgentSessionContextMeasurer { _, _ in
        publicCounts(contextSize: 8, transcript: -1)
      }
    )
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await negative.respond(to: "Negative")
    }
    #expect(negativeModel.recorder.capturedTranscripts().isEmpty)
  }

  @Test("Oversized instructions, tools, and prompt bypass history transforms")
  func oversizedFixedComponents() async throws {
    let transformCalls = PublicLockedValue(0)
    let transform = AgentSessionContextTransform(identifier: "must-not-run") { request in
      transformCalls.withLock { $0 += 1 }
      return AgentSessionContextTransformResult(
        transcript: request.transcript,
        affectedHistoryRange: 0..<request.transcript.history.count,
        provenance: "public probe"
      )
    }

    let instructionModel = RecordedLanguageModel(steps: [.response(text: "unused")])
    let instructionSession = try AgentSession(
      model: instructionModel,
      instructions: Instructions("Large instructions."),
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .transform(transform)
        )
      ),
      contextMeasurer: AgentSessionContextMeasurer { _, request in
        publicCounts(
          contextSize: 4,
          instructions: request.instructions == nil ? 0 : 5
        )
      }
    )
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await instructionSession.respond(to: "Instructions")
    }

    let toolModel = RecordedLanguageModel(steps: [.response(text: "unused")])
    let toolSession = try AgentSession(
      model: toolModel,
      tools: [PublicBudgetTool()],
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .transform(transform)
        )
      ),
      contextMeasurer: AgentSessionContextMeasurer { _, request in
        publicCounts(contextSize: 4, tools: request.tools.isEmpty ? 0 : 5)
      }
    )
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await toolSession.respond(to: "Tools")
    }

    let promptModel = RecordedLanguageModel(steps: [.response(text: "unused")])
    let promptSession = try AgentSession(
      model: promptModel,
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .transform(transform)
        )
      ),
      contextMeasurer: AgentSessionContextMeasurer { _, _ in
        publicCounts(contextSize: 4, prompt: 5)
      }
    )
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await promptSession.respond(to: "Prompt")
    }

    #expect(transformCalls.value == 0)
    #expect(instructionModel.recorder.capturedTranscripts().isEmpty)
    #expect(toolModel.recorder.capturedTranscripts().isEmpty)
    #expect(promptModel.recorder.capturedTranscripts().isEmpty)
  }

  @Test("Fail policy rejects oversized history before a second inference")
  func oversizedHistoryFailPolicy() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(text: "one"),
      .response(text: "unused"),
    ])
    let session = try AgentSession(
      model: model,
      configuration: .init(
        contextBudget: .init(reservedResponseTokens: 0)
      ),
      contextMeasurer: AgentSessionContextMeasurer { _, request in
        publicCounts(
          contextSize: 3,
          transcript: request.transcriptEntries.count * 2
        )
      }
    )

    _ = try await session.respond(to: "First")
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await session.respond(to: "Second")
    }
    #expect(model.recorder.capturedTranscripts().count == 1)
  }

  @Test("Transform rematerializes active history and preserves authoritative checkpoint")
  func transformAndCheckpoint() async throws {
    let store = InMemoryCheckpointStore()
    let probe = PublicProbe()
    let transform = AgentSessionContextTransform(identifier: "public-window") { request in
      var transcript = request.transcript
      let affected = 0..<transcript.history.count
      transcript.history = []
      return AgentSessionContextTransformResult(
        transcript: transcript,
        affectedHistoryRange: affected,
        provenance: "public consumer rolling window",
        authoritativeTranscriptPolicy: .preserve
      )
    }
    let model = RecordedLanguageModel(steps: [
      .response(text: "one"),
      .response(text: "two"),
    ])
    let session = try AgentSession(
      model: model,
      instructions: Instructions("Current instructions."),
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .transform(transform)
        )
      ),
      contextMeasurer: AgentSessionContextMeasurer { _, request in
        await probe.record(request)
        return publicCounts(
          contextSize: 3,
          transcript: request.transcriptEntries.count * 2
        )
      },
      checkpointStore: store
    )

    _ = try await session.respond(to: "First")
    let response = try await session.respond(to: "Second")

    #expect(model.recorder.capturedTranscripts()[1].history.count == 1)
    #expect(try await session.transcript().history.count == 4)
    #expect(await store.loadCheckpoint(for: "default")?.transcript.history.count == 4)
    let transformed = try #require(
      response.run.events.first { $0.kind == .contextBudgetTransformed })
    #expect(transformed.attributes["cache_invalidated"] == "true")
    #expect(transformed.attributes["affected_history_range"] == "0..<2")
    let measurements = await probe.measurements
    #expect(measurements.count == 3)
    #expect(measurements.last?.transcriptEntries.isEmpty == true)
    #expect(measurements.last?.instructionEntries.isEmpty == false)
  }

  @Test("Automatic summarization is available to an external consumer")
  func automaticSummarization() async throws {
    let summarizer = RecordedLanguageModel(steps: [.response(text: "Public compact state.")])
    let model = RecordedLanguageModel(steps: [
      .response(text: "one"),
      .response(text: "two"),
    ])
    let session = try AgentSession(
      model: model,
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .summarize(
            using: summarizer,
            identifier: "public-summary-v1"
          )
        )
      ),
      contextMeasurer: AgentSessionContextMeasurer { _, request in
        let containsSummary = request.transcriptEntries.contains {
          $0.id.hasPrefix("foundation-models-agent-summary-")
        }
        return publicCounts(
          contextSize: 8,
          transcript: containsSummary ? 2 : request.transcriptEntries.count * 4
        )
      }
    )

    _ = try await session.respond(to: "First")
    let response = try await session.respond(to: "Second")

    #expect(response.content == "two")
    #expect(summarizer.recorder.capturedTranscripts().count == 1)
    let transformed = try #require(
      response.run.events.first { $0.kind == .contextBudgetTransformed })
    #expect(transformed.attributes["selected_policy"] == "transform:public-summary-v1")
    #expect(try await session.transcript().history.count == 4)
  }

  @Test("Structured and streaming paths account for schema before inference")
  func structuredAndStreaming() async throws {
    let structuredProbe = PublicProbe()
    let structured = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: #"{"value":"ok"}"#)]),
      configuration: .init(contextBudget: .init(reservedResponseTokens: 0)),
      contextMeasurer: AgentSessionContextMeasurer { _, request in
        await structuredProbe.record(request)
        return publicCounts(
          contextSize: 8,
          schema: request.schema == nil ? 0 : 3
        )
      }
    )
    #expect(
      try await structured.respond(to: "Structured", generating: PublicBudgetAnswer.self)
        .content.value == "ok"
    )
    #expect(await structuredProbe.measurements.first?.schema != nil)

    let streamingProbe = PublicProbe()
    let streamingModel = RecordedLanguageModel(steps: [
      .responseFragments([#"{"value":"#, #""stream"}"#])
    ])
    let streaming = try AgentSession(
      model: streamingModel,
      configuration: .init(contextBudget: .init(reservedResponseTokens: 0)),
      contextMeasurer: AgentSessionContextMeasurer { _, request in
        await streamingProbe.record(request)
        return publicCounts(
          contextSize: 8,
          schema: request.schema == nil ? 0 : 3
        )
      }
    )
    let response = try await streaming.respondStreaming(
      to: "Stream",
      generating: PublicBudgetAnswer.self
    ) { _ in
      await streamingProbe.recordPartial()
    }
    #expect(response.content.value == "stream")
    #expect(await streamingProbe.measurements.first?.schema != nil)
    #expect(await streamingProbe.partialCount > 0)
  }

  @Test("Atomic routed session measures the selected model, not route metadata")
  func routedMeasurement() async throws {
    let primary = RecordedLanguageModel(steps: [.response(text: "unused")])
    let fallback = RecordedLanguageModel(steps: [.response(text: "fallback")])
    let result = FoundationModelsAgentRouter().select(
      from: [
        publicCandidate(id: "primary", model: primary, declaredContext: 8_192),
        publicCandidate(id: "fallback", model: fallback, declaredContext: 16_384),
      ],
      policy: ClosureFoundationModelsAgentRoutingPolicy { _, _ in
        FoundationModelsAgentRoutePlan(
          primaryRouteID: "primary",
          fallbackRouteIDs: ["fallback"]
        )
      }
    )
    let selection = try #require(result.selection)
    let session = try AgentSession(
      selection: selection,
      configuration: .init(
        contextBudget: .init(reservedResponseTokens: 0)
      ),
      contextMeasurer: AgentSessionContextMeasurer { model, _ in
        let selected = try #require(model as? RecordedLanguageModel)
        #expect(selected.recorder === primary.recorder)
        return publicCounts(contextSize: 4, prompt: 5)
      }
    )

    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await session.respond(to: "Use route")
    }

    let run = try #require(await session.lastRun())
    let routeIndex = try #require(
      run.events.firstIndex { $0.kind == .routeSelected })
    let failureIndex = try #require(
      run.events.firstIndex { $0.kind == .contextBudgetFailed })
    #expect(routeIndex < failureIndex)
    #expect(!run.events.contains { $0.kind == .modelAttemptStarted })
    #expect(run.routingDecision == selection.decision)
    #expect(primary.recorder.capturedTranscripts().isEmpty)
    #expect(fallback.recorder.capturedTranscripts().isEmpty)
  }

  @Test("A restored checkpoint is measured before the first resumed inference")
  func restoredCheckpointMeasurement() async throws {
    let store = InMemoryCheckpointStore()
    let first = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "persisted")]),
      checkpointStore: store
    )
    _ = try await first.respond(to: "First")

    let probe = PublicProbe()
    let resumedModel = RecordedLanguageModel(steps: [.response(text: "resumed")])
    let resumed = try AgentSession(
      model: resumedModel,
      instructions: Instructions("Current restored instructions."),
      configuration: .init(contextBudget: .init(reservedResponseTokens: 0)),
      contextMeasurer: AgentSessionContextMeasurer { _, request in
        await probe.record(request)
        return publicCounts(
          contextSize: 100,
          transcript: request.transcriptEntries.count
        )
      },
      checkpointStore: store
    )

    _ = try await resumed.respond(to: "Second")
    let firstMeasurement = try #require(await probe.measurements.first)
    #expect(firstMeasurement.transcriptEntries.count == 2)
    #expect(!firstMeasurement.instructionEntries.isEmpty)
    #expect(resumedModel.recorder.capturedTranscripts().first?.history.count == 3)
  }

  @Test("Opaque governed dynamic profiles reject context budgets")
  func governedProfileRejection() throws {
    let registry = try DynamicProfileToolRegistry(manifests: [])
    let governance = try DynamicProfileToolGovernanceConfiguration(trusting: registry)

    #expect(throws: FoundationModelsAgentError.self) {
      _ = try AgentSession(
        checkpointCompatibilityID: "public-opaque-profile",
        configuration: .init(contextBudget: .init()),
        toolGovernance: governance
      ) {
        PublicBudgetProfile(
          model: RecordedLanguageModel(steps: [.response(text: "unused")])
        )
      }
    }
  }
}
