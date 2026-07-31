import Foundation
import FoundationModels
import FoundationModelsAgentTestSupport
import Testing

@testable import FoundationModelsAgent

@Generable
private struct BudgetAnswer: Sendable {
  let value: String
}

@Generable
private struct BudgetToolArguments: Sendable {
  let value: String
}

private struct BudgetTool: Tool {
  let name = "budget_tool"
  let description = "Returns the supplied value."

  @concurrent
  func call(arguments: BudgetToolArguments) async throws -> String {
    arguments.value
  }
}

private struct BudgetDynamicProfile: LanguageModelSession.DynamicProfile {
  let model: RecordedLanguageModel

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Dynamic profile instructions.")
    }
    .model(model)
  }
}

private final class TransformProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func record() {
    lock.withLock { value += 1 }
  }

  var count: Int {
    lock.withLock { value }
  }
}

private final class MeasurementTranscriptProbe: @unchecked Sendable {
  struct Snapshot {
    let instructionEntryIDs: [String]
    let historyEntryIDs: [String]
  }

  private let lock = NSLock()
  private var value: [Snapshot] = []

  func record(_ request: AgentSessionContextMeasurementRequest) {
    lock.withLock {
      value.append(
        Snapshot(
          instructionEntryIDs: request.instructionEntries.map(\.id),
          historyEntryIDs: request.transcriptEntries.map(\.id)
        ))
    }
  }

  var snapshots: [Snapshot] {
    lock.withLock { value }
  }
}

private actor MeasurementGate {
  private(set) var started = false

  func markStarted() {
    started = true
  }
}

private func fixedMeasurer(
  contextSize: Int,
  instructions: Int = 0,
  tools: Int = 0,
  prompt: Int = 1,
  schema: Int = 0,
  transcript: Int = 0
) -> AgentSessionContextMeasurer {
  AgentSessionContextMeasurer { _, _ in
    AgentSessionContextTokenCounts(
      contextSize: contextSize,
      instructions: instructions,
      tools: tools,
      prompt: prompt,
      schema: schema,
      transcript: transcript
    )
  }
}

private func transcriptText(_ transcript: Transcript) -> String {
  transcript.compactMap { entry -> String? in
    switch entry {
    case .instructions(let instructions):
      instructions.description
    case .prompt(let prompt):
      prompt.segments.map(\.description).joined(separator: " ")
    case .response(let response):
      response.segments.map(\.description).joined(separator: " ")
    case .toolCalls(let calls):
      calls.description
    case .toolOutput(let output):
      output.description
    case .reasoning:
      nil
    @unknown default:
      nil
    }
  }
  .joined(separator: "\n")
}

private func automaticSummaryMeasurer(contextSize: Int = 8) -> AgentSessionContextMeasurer {
  AgentSessionContextMeasurer { _, request in
    let containsSummary = request.transcriptEntries.contains {
      $0.id.hasPrefix("foundation-models-agent-summary-")
    }
    return AgentSessionContextTokenCounts(
      contextSize: contextSize,
      instructions: 0,
      tools: 0,
      prompt: 1,
      schema: 0,
      transcript: containsSummary ? 2 : request.transcriptEntries.count * 4
    )
  }
}

@Suite("AgentSession context budgets")
struct AgentSessionContextBudgetTests {
  @Test("Tool definitions cannot be hidden by a smaller instruction-entry count")
  func materializedToolTokensDoNotUndercount() {
    let toolsDominate = AgentSessionContextTokenCounts.splitMaterializedInstructionTokens(
      combinedTokens: 7,
      toolTokens: 11
    )
    #expect(toolsDominate.instructions == 0)
    #expect(toolsDominate.tools == 11)

    let combinedDominates = AgentSessionContextTokenCounts.splitMaterializedInstructionTokens(
      combinedTokens: 17,
      toolTokens: 11
    )
    #expect(combinedDominates.instructions == 6)
    #expect(combinedDominates.tools == 11)
  }

  @Test("SystemLanguageModel selects native measurement automatically")
  func systemModelNativeMeasurement() throws {
    _ = try AgentSession(
      model: SystemLanguageModel.default,
      configuration: .init(
        contextBudget: .init(reservedResponseTokens: 512)
      )
    )
  }

  @Test("Allows an exact fit and records every component")
  func exactFit() async throws {
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "fit")]),
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 1,
          maximumUsableFraction: 1
        )
      ),
      contextMeasurer: fixedMeasurer(
        contextSize: 10,
        instructions: 1,
        tools: 1,
        prompt: 3,
        schema: 1,
        transcript: 3
      )
    )

    let response = try await session.respond(to: "Fit")

    #expect(response.content == "fit")
    let event = try #require(
      response.run.events.first { $0.kind == .contextBudgetEvaluated })
    #expect(event.attributes["before_total_input_tokens"] == "9")
    #expect(event.attributes["before_usable_input_tokens"] == "9")
    #expect(event.attributes["selected_policy"] == "fail_before_inference")
  }

  @Test("Reserved response headroom reduces usable input")
  func reservedHeadroom() async throws {
    let model = RecordedLanguageModel(steps: [.response(text: "unused")])
    let session = try AgentSession(
      model: model,
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 2,
          maximumUsableFraction: 1
        )
      ),
      contextMeasurer: fixedMeasurer(contextSize: 10, prompt: 9)
    )

    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await session.respond(to: "Too large")
    }

    #expect(model.recorder.capturedTranscripts().isEmpty)
    let run = try #require(await session.lastRun())
    #expect(
      run.events.contains {
        $0.kind == .contextBudgetFailed
          && $0.attributes["selected_policy"] == "fail_before_inference"
      })
  }

  @Test("Fractional and absolute caps choose the smaller input limit")
  func fractionalAndAbsoluteCaps() async throws {
    let model = RecordedLanguageModel(steps: [.response(text: "unused")])
    let session = try AgentSession(
      model: model,
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          maximumUsableFraction: 0.75,
          maximumUsableTokens: 6
        )
      ),
      contextMeasurer: fixedMeasurer(contextSize: 12, prompt: 7)
    )

    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await session.respond(to: "Absolute cap")
    }

    let run = try #require(await session.lastRun())
    let event = try #require(
      run.events.first { $0.kind == .contextBudgetEvaluated })
    #expect(event.attributes["before_usable_input_tokens"] == "6")
  }

  @Test("Prompt overflow fails without invoking a history transform")
  func promptOverflow() async throws {
    let probe = TransformProbe()
    let transform = AgentSessionContextTransform(identifier: "never-called") { request in
      probe.record()
      return AgentSessionContextTransformResult(
        transcript: request.transcript,
        affectedHistoryRange: 0..<1,
        provenance: "test"
      )
    }
    let model = RecordedLanguageModel(steps: [.response(text: "unused")])
    let session = try AgentSession(
      model: model,
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          maximumUsableFraction: 1,
          overflowPolicy: .transform(transform)
        )
      ),
      contextMeasurer: fixedMeasurer(
        contextSize: 8,
        instructions: 2,
        tools: 1,
        prompt: 6
      )
    )

    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await session.respond(to: "Fixed overflow")
    }

    #expect(probe.count == 0)
    #expect(model.recorder.capturedTranscripts().isEmpty)
  }

  @Test("Includes native tools and an applicable schema")
  func toolAndSchemaCost() async throws {
    let measurer = AgentSessionContextMeasurer { _, request in
      AgentSessionContextTokenCounts(
        contextSize: 20,
        instructions: request.instructions == nil ? 0 : 2,
        tools: request.tools.isEmpty ? 0 : 3,
        prompt: 1,
        schema: request.schema == nil ? 0 : 4,
        transcript: request.transcriptEntries.count
      )
    }
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: #"{"value":"ok"}"#)]),
      tools: [BudgetTool()],
      instructions: Instructions("Use the tool when needed."),
      configuration: .init(
        contextBudget: .init(reservedResponseTokens: 2)
      ),
      contextMeasurer: measurer
    )

    let response = try await session.respond(
      to: "Answer",
      generating: BudgetAnswer.self
    )

    let event = try #require(
      response.run.events.first { $0.kind == .contextBudgetEvaluated })
    #expect(event.attributes["before_instructions_tokens"] == "2")
    #expect(event.attributes["before_tools_tokens"] == "3")
    #expect(event.attributes["before_schema_tokens"] == "4")
  }

  @Test("Transforms active history while preserving the authoritative checkpoint")
  func transformedHistory() async throws {
    let store = InMemoryCheckpointStore()
    let transform = AgentSessionContextTransform(identifier: "drop-complete-history") { request in
      var transcript = request.transcript
      let affected = 0..<transcript.history.count
      transcript.history = []
      return AgentSessionContextTransformResult(
        transcript: transcript,
        affectedHistoryRange: affected,
        provenance: "test rolling window",
        authoritativeTranscriptPolicy: .preserve
      )
    }
    let measurer = AgentSessionContextMeasurer { _, request in
      AgentSessionContextTokenCounts(
        contextSize: 6,
        instructions: 0,
        tools: 0,
        prompt: 1,
        schema: 0,
        transcript: request.transcriptEntries.count * 3
      )
    }
    let model = RecordedLanguageModel(steps: [
      .response(text: "one"),
      .response(text: "two"),
    ])
    let session = try AgentSession(
      model: model,
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .transform(transform)
        )
      ),
      contextMeasurer: measurer,
      checkpointStore: store
    )

    _ = try await session.respond(to: "First")
    let second = try await session.respond(to: "Second")

    let requests = model.recorder.capturedTranscripts()
    #expect(requests.count == 2)
    #expect(requests[1].history.count == 1)
    #expect(try await session.transcript().history.count == 4)
    let checkpoint = try #require(await store.loadCheckpoint(for: "default"))
    #expect(checkpoint.transcript.history.count == 4)
    let event = try #require(
      second.run.events.first { $0.kind == .contextBudgetTransformed })
    #expect(event.attributes["before_total_input_tokens"] == "7")
    #expect(event.attributes["after_total_input_tokens"] == "1")
    #expect(event.attributes["affected_history_range"] == "0..<2")
    #expect(event.attributes["provenance"] == "test rolling window")
    #expect(event.attributes["cache_invalidated"] == "true")
    #expect(event.attributes["authoritative_transcript_policy"] == "preserve")
  }

  @Test("Automatic summarization uses a fresh model and preserves complete history")
  func automaticSummaryPreservesCompleteHistory() async throws {
    let summarizer = RecordedLanguageModel(steps: [
      .response(text: "The user started a two-turn conversation.")
    ])
    let mainModel = RecordedLanguageModel(steps: [
      .response(text: "first answer"),
      .response(text: "second answer"),
    ])
    let store = InMemoryCheckpointStore()
    let session = try AgentSession(
      model: mainModel,
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .summarize(using: summarizer)
        )
      ),
      contextMeasurer: automaticSummaryMeasurer(),
      checkpointStore: store
    )

    _ = try await session.respond(to: "First question")
    let second = try await session.respond(to: "Second question")

    let summarizerRequests = summarizer.recorder.capturedTranscripts()
    #expect(summarizerRequests.count == 1)
    let summarizerText = transcriptText(try #require(summarizerRequests.first))
    #expect(summarizerText.contains("First question"))
    #expect(summarizerText.contains("first answer"))

    let mainRequests = mainModel.recorder.capturedTranscripts()
    #expect(mainRequests.count == 2)
    let compactedText = transcriptText(mainRequests[1])
    #expect(compactedText.contains("The user started a two-turn conversation."))
    #expect(compactedText.contains("Second question"))
    #expect(!compactedText.contains("First question"))

    #expect(try await session.transcript().history.count == 4)
    let checkpoint = try #require(await store.loadCheckpoint(for: "default"))
    #expect(checkpoint.transcript.history.count == 4)
    let event = try #require(
      second.run.events.first { $0.kind == .contextBudgetTransformed })
    #expect(event.attributes["before_total_input_tokens"] == "9")
    #expect(event.attributes["after_total_input_tokens"] == "3")
    #expect(event.attributes["selected_policy"] == "transform:automatic-summary-v1")
    #expect(event.attributes["provenance"]?.hasPrefix("automatic-summary:") == true)
    #expect(event.attributes["authoritative_transcript_policy"] == "preserve")
  }

  @Test("Automatic summarization renders completed tool evidence")
  func automaticSummaryRendersToolEvidence() async throws {
    let summarizer = RecordedLanguageModel(steps: [
      .response(text: "The lookup returned forty-two.")
    ])
    let mainModel = RecordedLanguageModel(steps: [
      .toolCall(
        id: "lookup-call",
        name: "budget_tool",
        argumentsJSON: #"{"value":"question"}"#
      ),
      .response(text: "first answer"),
      .response(text: "second answer"),
    ])
    let session = try AgentSession(
      model: mainModel,
      tools: [BudgetTool()],
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .summarize(using: summarizer)
        )
      ),
      contextMeasurer: automaticSummaryMeasurer(contextSize: 12)
    )

    _ = try await session.respond(to: "Use the tool")
    _ = try await session.respond(to: "Continue")

    let request = try #require(summarizer.recorder.capturedTranscripts().first)
    let rendered = transcriptText(request)
    #expect(rendered.contains("budget_tool"))
    #expect(rendered.contains("question"))
  }

  @Test("Automatic summarization can redact its source before model disclosure")
  func automaticSummaryRedactsSource() async throws {
    let summarizer = RecordedLanguageModel(steps: [.response(text: "Redacted state.")])
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "first answer"),
        .response(text: "second answer"),
      ]),
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .summarize(
            using: summarizer,
            sourceRedactionPolicy: .standard
          )
        )
      ),
      contextMeasurer: automaticSummaryMeasurer()
    )

    _ = try await session.respond(to: "Remember api_key=fixture-secret-value")
    _ = try await session.respond(to: "Continue")

    let request = try #require(summarizer.recorder.capturedTranscripts().first)
    let rendered = transcriptText(request)
    #expect(!rendered.contains("fixture-secret-value"))
    #expect(rendered.contains("api_key=[REDACTED]"))
  }

  @Test("Automatic summarization can explicitly replace authoritative history")
  func automaticSummaryCanReplaceAuthoritativeHistory() async throws {
    let summarizer = RecordedLanguageModel(steps: [.response(text: "Compacted state.")])
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "first answer"),
        .response(text: "second answer"),
      ]),
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .summarize(
            using: summarizer,
            authoritativeTranscriptPolicy: .replace
          )
        )
      ),
      contextMeasurer: automaticSummaryMeasurer()
    )

    _ = try await session.respond(to: "First question")
    _ = try await session.respond(to: "Second question")

    let history = Array(try await session.transcript().history)
    #expect(history.count == 4)
    #expect(history[0].id.hasPrefix("foundation-models-agent-summary-prompt-"))
    #expect(history[1].id.hasPrefix("foundation-models-agent-summary-response-"))
  }

  @Test("Automatic summarization fails before main inference for an empty summary")
  func automaticSummaryRejectsEmptyOutput() async throws {
    let summarizer = RecordedLanguageModel(steps: [.response(text: " \n ")])
    let mainModel = RecordedLanguageModel(steps: [
      .response(text: "first answer"),
      .response(text: "unused"),
    ])
    let session = try AgentSession(
      model: mainModel,
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .summarize(using: summarizer)
        )
      ),
      contextMeasurer: automaticSummaryMeasurer()
    )

    _ = try await session.respond(to: "First question")
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await session.respond(to: "Second question")
    }

    #expect(mainModel.recorder.capturedTranscripts().count == 1)
    let run = try #require(await session.lastRun())
    #expect(run.events.contains { $0.kind == .contextBudgetFailed })
  }

  @Test("An explicit lossy transform replaces the authoritative checkpoint")
  func lossyTransformedHistory() async throws {
    let store = InMemoryCheckpointStore()
    let transform = AgentSessionContextTransform(identifier: "lossy-window") { request in
      var transcript = request.transcript
      let affected = 0..<transcript.history.count
      transcript.history = []
      return AgentSessionContextTransformResult(
        transcript: transcript,
        affectedHistoryRange: affected,
        provenance: "user selected lossy window",
        authoritativeTranscriptPolicy: .replace
      )
    }
    let measurer = AgentSessionContextMeasurer { _, request in
      AgentSessionContextTokenCounts(
        contextSize: 6,
        instructions: 0,
        tools: 0,
        prompt: 1,
        schema: 0,
        transcript: request.transcriptEntries.count * 3
      )
    }
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "one"),
        .response(text: "two"),
      ]),
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .transform(transform)
        )
      ),
      contextMeasurer: measurer,
      checkpointStore: store
    )

    _ = try await session.respond(to: "First")
    let second = try await session.respond(to: "Second")

    #expect(try await session.transcript().history.count == 2)
    let checkpoint = try #require(await store.loadCheckpoint(for: "default"))
    #expect(checkpoint.transcript.history.count == 2)
    let event = try #require(
      second.run.events.first { $0.kind == .contextBudgetTransformed })
    #expect(event.attributes["authoritative_transcript_policy"] == "replace")
  }

  @Test("Explicit bounded retention remains lossy after a preserving transform")
  func preservingTransformWithBoundedRetention() async throws {
    let store = InMemoryCheckpointStore()
    let transform = AgentSessionContextTransform(identifier: "preserve-then-retain") {
      request in
      var transcript = request.transcript
      let affected = 0..<transcript.history.count
      transcript.history = []
      return AgentSessionContextTransformResult(
        transcript: transcript,
        affectedHistoryRange: affected,
        provenance: "explicit persistence boundary",
        authoritativeTranscriptPolicy: .preserve
      )
    }
    let measurer = AgentSessionContextMeasurer { _, request in
      AgentSessionContextTokenCounts(
        contextSize: 6,
        instructions: 0,
        tools: 0,
        prompt: 1,
        schema: 0,
        transcript: request.transcriptEntries.count * 3
      )
    }
    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "one"),
        .response(text: "two"),
      ]),
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .transform(transform)
        )
      ),
      contextMeasurer: measurer,
      checkpointStore: store,
      transcriptRetention: .latestHistoryEntries(2)
    )

    _ = try await session.respond(to: "First")
    _ = try await session.respond(to: "Second")

    #expect(try await session.transcript().history.count == 4)
    let checkpoint = try #require(await store.loadCheckpoint(for: "default"))
    #expect(checkpoint.transcript.history.count == 2)
  }

  @Test("Remeasures the transcript rematerialized for inference")
  func remeasuresRematerializedTranscript() async throws {
    let probe = MeasurementTranscriptProbe()
    let transform = AgentSessionContextTransform(identifier: "rematerialize") { request in
      var transcript = request.transcript
      let affected = 0..<transcript.history.count
      transcript.history = []
      return AgentSessionContextTransformResult(
        transcript: transcript,
        affectedHistoryRange: affected,
        provenance: "test rematerialization"
      )
    }
    let measurer = AgentSessionContextMeasurer { _, request in
      probe.record(request)
      return AgentSessionContextTokenCounts(
        contextSize: 6,
        instructions: 0,
        tools: 0,
        prompt: 1,
        schema: 0,
        transcript: request.transcriptEntries.count * 3
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
      contextMeasurer: measurer
    )

    _ = try await session.respond(to: "First")
    _ = try await session.respond(to: "Second")

    let snapshots = probe.snapshots
    #expect(snapshots.count == 3)
    #expect(snapshots[2].historyEntryIDs.isEmpty)
    let requests = model.recorder.capturedTranscripts()
    let inferredInstructionIDs = requests[1].compactMap { entry -> String? in
      if case .instructions = entry { return entry.id }
      return nil
    }
    #expect(snapshots[2].instructionEntryIDs == inferredInstructionIDs)
  }

  @Test("A transform that still overflows records post-transform counts")
  func transformedHistoryStillOverflows() async throws {
    let transform = AgentSessionContextTransform(identifier: "no-op") { request in
      AgentSessionContextTransformResult(
        transcript: request.transcript,
        affectedHistoryRange: 0..<request.transcript.history.count,
        provenance: "deliberate no-op"
      )
    }
    let measurer = AgentSessionContextMeasurer { _, request in
      AgentSessionContextTokenCounts(
        contextSize: 4,
        instructions: 0,
        tools: 0,
        prompt: 1,
        schema: 0,
        transcript: request.transcriptEntries.count * 2
      )
    }
    let model = RecordedLanguageModel(steps: [
      .response(text: "one"),
      .response(text: "unused"),
    ])
    let session = try AgentSession(
      model: model,
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .transform(transform)
        )
      ),
      contextMeasurer: measurer
    )
    _ = try await session.respond(to: "First")

    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await session.respond(to: "Second")
    }

    #expect(model.recorder.capturedTranscripts().count == 1)
    let run = try #require(await session.lastRun())
    let event = try #require(
      run.events.first { $0.kind == .contextBudgetFailed })
    #expect(event.attributes["before_total_input_tokens"] == "5")
    #expect(event.attributes["after_total_input_tokens"] == "5")
    #expect(event.attributes["provenance"] == "deliberate no-op")
  }

  @Test("Rejects a transform that orphans a tool output")
  func orphanedToolTurnPrevention() async throws {
    let transform = AgentSessionContextTransform(identifier: "orphan-output") { request in
      let output = Transcript.Entry.toolOutput(
        .init(
          id: "missing-call",
          toolName: "budget_tool",
          segments: [.text(.init(content: "orphan"))]
        )
      )
      var transcript = request.transcript
      transcript.history = [output]
      return AgentSessionContextTransformResult(
        transcript: transcript,
        affectedHistoryRange: 0..<request.transcript.history.count,
        provenance: "invalid test transform"
      )
    }
    let measurer = AgentSessionContextMeasurer { _, request in
      AgentSessionContextTokenCounts(
        contextSize: 3,
        instructions: 0,
        tools: 0,
        prompt: 1,
        schema: 0,
        transcript: request.transcriptEntries.count * 2
      )
    }
    let model = RecordedLanguageModel(steps: [
      .response(text: "one"),
      .response(text: "unused"),
    ])
    let session = try AgentSession(
      model: model,
      configuration: .init(
        contextBudget: .init(
          reservedResponseTokens: 0,
          overflowPolicy: .transform(transform)
        )
      ),
      contextMeasurer: measurer
    )
    _ = try await session.respond(to: "First")

    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await session.respond(to: "Second")
    }

    #expect(model.recorder.capturedTranscripts().count == 1)
  }

  @Test("Rejects context budgeting for an opaque dynamic profile")
  func dynamicProfileLimitation() {
    #expect(throws: FoundationModelsAgentError.self) {
      _ = try AgentSession(
        checkpointCompatibilityID: "budget-profile",
        configuration: .init(
          contextBudget: .init(reservedResponseTokens: 1)
        )
      ) {
        BudgetDynamicProfile(
          model: RecordedLanguageModel(steps: [.response(text: "unused")])
        )
      }
    }
  }

  @Test("Cancellation during measurement never reaches inference")
  func measurementCancellation() async throws {
    let gate = MeasurementGate()
    let model = RecordedLanguageModel(steps: [.response(text: "unused")])
    let measurer = AgentSessionContextMeasurer { _, _ in
      await gate.markStarted()
      try await Task.sleep(for: .seconds(30))
      return AgentSessionContextTokenCounts(
        contextSize: 10,
        instructions: 0,
        tools: 0,
        prompt: 1,
        schema: 0,
        transcript: 0
      )
    }
    let session = try AgentSession(
      model: model,
      configuration: .init(
        contextBudget: .init(reservedResponseTokens: 1)
      ),
      contextMeasurer: measurer
    )

    let task = Task {
      try await session.respond(to: "Cancel")
    }
    while !(await gate.started) {
      await Task.yield()
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(model.recorder.capturedTranscripts().isEmpty)
  }

  @Test("The same request respects each selected model's context size")
  func differentContextSizes() async throws {
    let fittingModel = RecordedLanguageModel(steps: [.response(text: "fit")])
    let fitting = try AgentSession(
      model: fittingModel,
      configuration: .init(
        contextBudget: .init(reservedResponseTokens: 0)
      ),
      contextMeasurer: fixedMeasurer(contextSize: 8, prompt: 8)
    )
    #expect(try await fitting.respond(to: "Exact").content == "fit")

    let smallerModel = RecordedLanguageModel(steps: [.response(text: "unused")])
    let smaller = try AgentSession(
      model: smallerModel,
      configuration: .init(
        contextBudget: .init(reservedResponseTokens: 0)
      ),
      contextMeasurer: fixedMeasurer(contextSize: 7, prompt: 8)
    )
    await #expect(throws: FoundationModelsAgentError.self) {
      _ = try await smaller.respond(to: "Overflow")
    }
    #expect(smallerModel.recorder.capturedTranscripts().isEmpty)
  }
}
