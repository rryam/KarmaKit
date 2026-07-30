import Evaluations
import Foundation
import FoundationModels
import FoundationModelsAgent

/// Errors produced while translating a stable FoundationModelsAgent fixture into Apple's
/// Evaluations types.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public enum FoundationModelsAgentEvaluationsError: Error, LocalizedError, Sendable {
  case notToolCall(stepID: String)
  case missingArguments(stepID: String)
  case malformedArguments(stepID: String)
  case unsupportedExactArgument(stepID: String, argumentName: String)

  public var errorDescription: String? {
    switch self {
    case .notToolCall(let stepID):
      "Trajectory step '\(stepID)' is not a tool call."
    case .missingArguments(let stepID):
      "Tool call '\(stepID)' has no canonical arguments."
    case .malformedArguments(let stepID):
      "Tool call '\(stepID)' does not contain a canonical JSON object."
    case .unsupportedExactArgument(let stepID, let argumentName):
      "Tool call '\(stepID)' uses a nested or null '\(argumentName)' argument that Apple's exact ArgumentValue cannot represent."
    }
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
extension FoundationModelsAgentTrajectory.Step {
  /// Converts one observed native tool call into an exact Apple `ToolExpectation`.
  ///
  /// Apple's `ArgumentValue` represents scalar values. This helper throws for nested objects,
  /// arrays, and null instead of silently weakening those expectations.
  public func exactToolExpectation() throws -> ToolExpectation {
    guard kind == .toolCall, let toolName else {
      throw FoundationModelsAgentEvaluationsError.notToolCall(stepID: id)
    }
    guard let canonicalArgumentsJSON else {
      throw FoundationModelsAgentEvaluationsError.missingArguments(stepID: id)
    }
    guard
      let object = try? JSONDecoder().decode(
        [String: EvaluationJSONValue].self,
        from: Data(canonicalArgumentsJSON.utf8)
      )
    else {
      throw FoundationModelsAgentEvaluationsError.malformedArguments(stepID: id)
    }

    let matchers = try object.keys.sorted().map { argumentName in
      let value = try object[argumentName].flatMap { try $0.argumentValue() }
      guard let value else {
        throw FoundationModelsAgentEvaluationsError.unsupportedExactArgument(
          stepID: id,
          argumentName: argumentName
        )
      }
      return ArgumentMatcher.exact(argumentName: argumentName, value: value)
    }
    return ToolExpectation(toolName, arguments: matchers)
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
extension TrajectoryExpectation {
  /// Creates an Apple trajectory expectation from a checked-in observed path.
  ///
  /// The observed calls become an ordered expectation with exact scalar argument matchers.
  /// Pass disallowed tool names for negative safety constraints, and set
  /// `allowsAdditionalToolCalls` to `false` to make unexpected calls fail.
  public init(
    foundationModelsAgentTrajectory trajectory: FoundationModelsAgentTrajectory,
    disallowedToolNames: [String] = [],
    allowsAdditionalToolCalls: Bool = false
  ) throws {
    let ordered = try trajectory.toolCalls.map { try $0.exactToolExpectation() }
    let disallowed = Array(Set(disallowedToolNames)).sorted().map {
      ToolExpectation($0)
    }
    self.init(ordered: ordered, unordered: [], disallowed: disallowed)
    self.allowsAdditionalCalls = allowsAdditionalToolCalls
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
extension FoundationModelsAgentTrajectoryFixture {
  /// Creates an Apple model sample from this deterministic fixture.
  ///
  /// The fixture's expected destination feeds content evaluators while its trajectory feeds
  /// `ToolCallEvaluator`.
  public func modelSample(
    prompt: Prompt,
    disallowedToolNames: [String] = [],
    allowsAdditionalToolCalls: Bool = false
  ) throws -> ModelSample<String> {
    let expectation = try TrajectoryExpectation(
      foundationModelsAgentTrajectory: trajectory,
      disallowedToolNames: disallowedToolNames,
      allowsAdditionalToolCalls: allowsAdditionalToolCalls
    )
    return ModelSample(
      prompt: prompt,
      expected: expectedDestination,
      expectations: expectation
    )
  }

  public func modelSample(
    prompt: String,
    disallowedToolNames: [String] = [],
    allowsAdditionalToolCalls: Bool = false
  ) throws -> ModelSample<String> {
    try modelSample(
      prompt: Prompt(prompt),
      disallowedToolNames: disallowedToolNames,
      allowsAdditionalToolCalls: allowsAdditionalToolCalls
    )
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
extension ModelSubject {
  /// Wraps a destination value and Apple's structured view of the exact native transcript.
  public init(
    foundationModelsAgentValue value: Value,
    transcript: Transcript
  ) {
    self.init(value: value, transcript: transcript.structuredTranscript)
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
extension ToolCallEvaluator {
  /// Supplies consistently named metrics for FoundationModelsAgent trajectory checks.
  public init(foundationModelsAgentMetricPrefix prefix: String = "agent_trajectory") {
    self.init(
      allPass: Metric("\(prefix)_all_pass"),
      percentagePass: Metric("\(prefix)_percentage_pass")
    )
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
private indirect enum EvaluationJSONValue: Decodable {
  case string(String)
  case integer(Int)
  case number(Double)
  case boolean(Bool)
  case null
  case array([Self])
  case object([String: Self])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Int.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([Self].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: Self].self))
    }
  }

  func argumentValue() throws -> ArgumentValue? {
    switch self {
    case .string(let value):
      .string(value)
    case .integer(let value):
      .int(value)
    case .number(let value):
      .double(value)
    case .boolean(let value):
      .bool(value)
    case .null, .array, .object:
      nil
    }
  }
}
