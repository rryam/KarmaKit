import Foundation
import FoundationModels

/// Token counts for every native component Foundation Models sends to a model.
public struct AgentSessionContextTokenCounts: Equatable, Sendable {
  public let contextSize: Int
  public let instructions: Int
  public let tools: Int
  public let prompt: Int
  public let schema: Int
  public let transcript: Int

  public init(
    contextSize: Int,
    instructions: Int,
    tools: Int,
    prompt: Int,
    schema: Int,
    transcript: Int
  ) {
    self.contextSize = contextSize
    self.instructions = instructions
    self.tools = tools
    self.prompt = prompt
    self.schema = schema
    self.transcript = transcript
  }

  public var fixedInputTokens: Int {
    [instructions, tools, prompt, schema].reduce(0, Self.saturatingAdd)
  }

  public var totalInputTokens: Int {
    Self.saturatingAdd(fixedInputTokens, transcript)
  }

  private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
  }

  static func splitMaterializedInstructionTokens(
    combinedTokens: Int,
    toolTokens: Int
  ) -> (instructions: Int, tools: Int) {
    (
      instructions: max(0, combinedTokens - toolTokens),
      tools: toolTokens
    )
  }
}

/// The native values a custom model measurer must account for.
///
/// The measurer receives the exact `Model` value passed to `AgentSession`; this
/// keeps model-specific measurement truthful without adding a provider or
/// tokenizer abstraction.
public struct AgentSessionContextMeasurementRequest: Sendable {
  public let instructions: Instructions?
  public let instructionEntries: [Transcript.Entry]
  public let tools: [any Tool]
  public let prompt: Prompt
  public let schema: GenerationSchema?
  public let transcriptEntries: [Transcript.Entry]

  public init(
    instructions: Instructions?,
    instructionEntries: [Transcript.Entry] = [],
    tools: [any Tool],
    prompt: Prompt,
    schema: GenerationSchema?,
    transcriptEntries: [Transcript.Entry]
  ) {
    self.instructions = instructions
    self.instructionEntries = instructionEntries
    self.tools = tools
    self.prompt = prompt
    self.schema = schema
    self.transcriptEntries = transcriptEntries
  }
}

/// A model-specific context measurer bound to the exact explicit model type.
public struct AgentSessionContextMeasurer<Model: LanguageModel>: Sendable {
  private let operation:
    @Sendable (Model, AgentSessionContextMeasurementRequest) async throws ->
      AgentSessionContextTokenCounts

  public init(
    _ operation:
      @escaping @Sendable (Model, AgentSessionContextMeasurementRequest) async throws ->
      AgentSessionContextTokenCounts
  ) {
    self.operation = operation
  }

  func measure(
    model: Model,
    request: AgentSessionContextMeasurementRequest
  ) async throws -> AgentSessionContextTokenCounts {
    try await operation(model, request)
  }
}

/// Whether a successful history rewrite also replaces the authoritative transcript.
public enum AgentSessionAuthoritativeTranscriptPolicy: String, Sendable {
  /// Keep the complete transcript for `transcript()` and checkpoint persistence.
  case preserve
  /// Make the rewritten transcript authoritative. This is an explicit lossy choice.
  case replace
}

/// Input supplied to an app-owned history transform after overflow is measured.
public struct AgentSessionContextTransformRequest: Sendable {
  public let transcript: Transcript
  public let prompt: Prompt
  public let schema: GenerationSchema?
  public let counts: AgentSessionContextTokenCounts
  public let usableInputTokens: Int

  public init(
    transcript: Transcript,
    prompt: Prompt,
    schema: GenerationSchema?,
    counts: AgentSessionContextTokenCounts,
    usableInputTokens: Int
  ) {
    self.transcript = transcript
    self.prompt = prompt
    self.schema = schema
    self.counts = counts
    self.usableInputTokens = usableInputTokens
  }
}

/// The audited result of an app-owned history transform.
public struct AgentSessionContextTransformResult: Sendable {
  public let transcript: Transcript
  public let affectedHistoryRange: Range<Int>
  public let provenance: String
  public let authoritativeTranscriptPolicy: AgentSessionAuthoritativeTranscriptPolicy

  public init(
    transcript: Transcript,
    affectedHistoryRange: Range<Int>,
    provenance: String,
    authoritativeTranscriptPolicy: AgentSessionAuthoritativeTranscriptPolicy = .preserve
  ) {
    self.transcript = transcript
    self.affectedHistoryRange = affectedHistoryRange
    self.provenance = provenance
    self.authoritativeTranscriptPolicy = authoritativeTranscriptPolicy
  }
}

/// An app-owned history rewrite. FoundationModelsAgent does not summarize or tokenize.
public struct AgentSessionContextTransform: Sendable {
  public let identifier: String
  private let operation:
    @Sendable (AgentSessionContextTransformRequest) async throws ->
      AgentSessionContextTransformResult

  public init(
    identifier: String,
    _ operation:
      @escaping @Sendable (AgentSessionContextTransformRequest) async throws ->
      AgentSessionContextTransformResult
  ) {
    self.identifier = identifier
    self.operation = operation
  }

  func transform(
    _ request: AgentSessionContextTransformRequest
  ) async throws -> AgentSessionContextTransformResult {
    try await operation(request)
  }
}

public enum AgentSessionContextOverflowPolicy: Sendable {
  /// Throw before starting native inference.
  case failBeforeInference
  /// Ask the app to rewrite history, then validate and remeasure it.
  case transform(AgentSessionContextTransform)
}

/// Deterministic limits for native Foundation Models context preflight.
public struct AgentSessionContextBudget: Sendable {
  public var reservedResponseTokens: Int
  public var maximumUsableFraction: Double
  public var maximumUsableTokens: Int?
  public var overflowPolicy: AgentSessionContextOverflowPolicy

  public init(
    reservedResponseTokens: Int = 512,
    maximumUsableFraction: Double = 1,
    maximumUsableTokens: Int? = nil,
    overflowPolicy: AgentSessionContextOverflowPolicy = .failBeforeInference
  ) {
    self.reservedResponseTokens = reservedResponseTokens
    self.maximumUsableFraction = maximumUsableFraction
    self.maximumUsableTokens = maximumUsableTokens
    self.overflowPolicy = overflowPolicy
  }

  func usableInputTokens(contextSize: Int) -> Int {
    let afterHeadroom = max(0, contextSize - reservedResponseTokens)
    let fractionLimit =
      if maximumUsableFraction == 1 {
        contextSize
      } else {
        max(0, Int((Double(contextSize) * maximumUsableFraction).rounded(.down)))
      }
    return min(afterHeadroom, fractionLimit, maximumUsableTokens ?? Int.max)
  }

  func validate() throws {
    guard reservedResponseTokens >= 0 else {
      throw FoundationModelsAgentError.invalidReservedResponseTokens(reservedResponseTokens)
    }
    guard maximumUsableFraction > 0, maximumUsableFraction <= 1 else {
      throw FoundationModelsAgentError.invalidMaximumUsableFraction(maximumUsableFraction)
    }
    if let maximumUsableTokens, maximumUsableTokens < 0 {
      throw FoundationModelsAgentError.invalidMaximumUsableTokens(maximumUsableTokens)
    }
    if case .transform(let transform) = overflowPolicy,
      transform.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw FoundationModelsAgentError.invalidContextTransform(
        "The transform identifier must not be empty.")
    }
  }
}

extension SystemLanguageModel {
  fileprivate func foundationModelsAgentTokenCounts(
    for request: AgentSessionContextMeasurementRequest
  ) async throws -> AgentSessionContextTokenCounts {
    try Task.checkCancellation()
    let measuredToolTokens = try await tokenCount(for: request.tools)
    let instructionTokens: Int
    let toolTokens: Int
    if !request.instructionEntries.isEmpty {
      let combinedTokens = try await tokenCount(for: request.instructionEntries)
      let split = AgentSessionContextTokenCounts.splitMaterializedInstructionTokens(
        combinedTokens: combinedTokens,
        toolTokens: measuredToolTokens
      )
      instructionTokens = split.instructions
      toolTokens = split.tools
    } else {
      toolTokens = measuredToolTokens
      if let instructions = request.instructions {
        instructionTokens = try await tokenCount(for: instructions)
      } else {
        instructionTokens = 0
      }
    }
    try Task.checkCancellation()
    let promptTokens = try await tokenCount(for: request.prompt)
    try Task.checkCancellation()
    let schemaTokens: Int
    if let schema = request.schema {
      schemaTokens = try await tokenCount(for: schema)
    } else {
      schemaTokens = 0
    }
    try Task.checkCancellation()
    let transcriptTokens = try await tokenCount(for: request.transcriptEntries)
    try Task.checkCancellation()
    return AgentSessionContextTokenCounts(
      contextSize: contextSize,
      instructions: instructionTokens,
      tools: toolTokens,
      prompt: promptTokens,
      schema: schemaTokens,
      transcript: transcriptTokens
    )
  }
}

struct ErasedAgentSessionContextMeasurer: Sendable {
  private let operation:
    @Sendable (AgentSessionContextMeasurementRequest) async throws ->
      AgentSessionContextTokenCounts

  init<Model: LanguageModel>(
    model: Model,
    custom: AgentSessionContextMeasurer<Model>?
  ) {
    if let custom {
      operation = { request in
        try await custom.measure(model: model, request: request)
      }
    } else if let systemModel = model as? SystemLanguageModel {
      operation = { request in
        try await systemModel.foundationModelsAgentTokenCounts(for: request)
      }
    } else {
      operation = { _ in
        throw FoundationModelsAgentError.contextMeasurementRequired
      }
    }
  }

  func measure(
    _ request: AgentSessionContextMeasurementRequest
  ) async throws -> AgentSessionContextTokenCounts {
    try await operation(request)
  }
}
