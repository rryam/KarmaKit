import Foundation
import FoundationModels

/// A stable, framework-independent record of the path an agent took through a native transcript.
///
/// `FoundationModelsAgentTrajectory` keeps Foundation Models as the runtime source of truth while
/// making observed tool calls and destination content suitable for deterministic regression
/// fixtures. It deliberately does not define a second transcript or message API.
public struct FoundationModelsAgentTrajectory: Codable, Equatable, Sendable {
  public static let currentFormatVersion = 1

  public enum FinalStatus: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case incomplete
  }

  public struct Step: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
      case instructions
      case prompt
      case toolCallGroup
      case toolCall
      case toolOutput
      case response
      case reasoning
      case unsupported
    }

    public enum ToolOutcome: String, Codable, Equatable, Sendable {
      case succeeded
      case denied
      case cancelled
      case failed
      case incomplete
    }

    public let sequence: Int
    public let id: String
    public let parentID: String?
    public let kind: Kind
    public let toolName: String?
    public let canonicalArgumentsJSON: String?
    public let toolOutcome: ToolOutcome?
    public let segments: [Segment]

    public init(
      sequence: Int,
      id: String,
      parentID: String? = nil,
      kind: Kind,
      toolName: String? = nil,
      canonicalArgumentsJSON: String? = nil,
      toolOutcome: ToolOutcome? = nil,
      segments: [Segment] = []
    ) {
      self.sequence = sequence
      self.id = id
      self.parentID = parentID
      self.kind = kind
      self.toolName = toolName
      self.canonicalArgumentsJSON = canonicalArgumentsJSON
      self.toolOutcome = toolOutcome
      self.segments = segments
    }
  }

  public struct Segment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
      case text
      case structure
      case unsupportedAttachment
      case unsupportedCustom
      case unsupported
    }

    public let id: String
    public let kind: Kind
    public let text: String?
    public let schemaName: String?
    public let canonicalContentJSON: String?
    public let unsupportedType: String?

    public init(
      id: String,
      kind: Kind,
      text: String? = nil,
      schemaName: String? = nil,
      canonicalContentJSON: String? = nil,
      unsupportedType: String? = nil
    ) {
      self.id = id
      self.kind = kind
      self.text = text
      self.schemaName = schemaName
      self.canonicalContentJSON = canonicalContentJSON
      self.unsupportedType = unsupportedType
    }
  }

  public struct Issue: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
      case ambiguousToolOutputLinkage
      case ambiguousToolOutcome
      case duplicateToolCallID
      case emptyToolCallGroup
      case malformedToolArguments
      case orphanedToolCall
      case orphanedToolOutput
      case toolNameMismatch
      case unsupportedAttachment
      case unsupportedCustomSegment
      case unsupportedTranscriptEntry
      case unsupportedTranscriptSegment
      case unresolvedToolCall
    }

    public let kind: Kind
    public let entryID: String
    public let detail: String

    public init(kind: Kind, entryID: String, detail: String) {
      self.kind = kind
      self.entryID = entryID
      self.detail = detail
    }
  }

  public let formatVersion: Int
  public let runID: UUID?
  public let finalStatus: FinalStatus
  public let steps: [Step]
  public let issues: [Issue]

  public init(
    formatVersion: Int = Self.currentFormatVersion,
    runID: UUID? = nil,
    finalStatus: FinalStatus,
    steps: [Step],
    issues: [Issue] = []
  ) {
    self.formatVersion = formatVersion
    self.runID = runID
    self.finalStatus = finalStatus
    self.steps = steps
    self.issues = issues
  }

  /// Builds a stable trajectory from Apple's native transcript and optional audited run evidence.
  ///
  /// Tool calls retain their native order and are parented to the native `ToolCalls` entry.
  /// Outputs are parented to their matching call ID. Unsupported attachment and custom segments
  /// remain explicit issues instead of being silently flattened or discarded.
  public init(
    transcript: Transcript,
    run: FoundationModelsAgentRun? = nil,
    redactionPolicy: FoundationModelsAgentRedactionPolicy = .standard,
    sensitiveArgumentNames: Set<String> = Self.defaultSensitiveArgumentNames
  ) {
    var builder = Builder(
      run: run,
      redactionPolicy: redactionPolicy,
      sensitiveArgumentNames: sensitiveArgumentNames
    )
    builder.append(transcript: transcript)
    self = builder.trajectory()
  }

  public static let defaultSensitiveArgumentNames: Set<String> = [
    "access_token",
    "api_key",
    "apikey",
    "authorization",
    "client_secret",
    "credential",
    "password",
    "private_key",
    "refresh_token",
    "secret",
    "token",
  ]

  /// Text in the last native response, useful as the destination value for content evaluators.
  public var destinationText: String? {
    guard let response = steps.last(where: { $0.kind == .response }) else { return nil }
    let values = response.segments.compactMap(\.text)
    return values.isEmpty ? nil : values.joined()
  }

  /// Native tool calls in the exact order in which they appeared in the transcript.
  public var toolCalls: [Step] {
    steps.filter { $0.kind == .toolCall }
  }
}

/// A versioned, deterministic artifact intended for checked-in regression datasets.
public struct FoundationModelsAgentTrajectoryFixture: Codable, Equatable, Sendable {
  public static let currentFormatVersion = 1

  public let formatVersion: Int
  public let name: String
  public let expectedDestination: String?
  public let trajectory: FoundationModelsAgentTrajectory

  public init(
    formatVersion: Int = Self.currentFormatVersion,
    name: String,
    expectedDestination: String? = nil,
    trajectory: FoundationModelsAgentTrajectory
  ) {
    self.formatVersion = formatVersion
    self.name = name
    self.expectedDestination = expectedDestination
    self.trajectory = trajectory
  }
}

public struct FoundationModelsAgentTrajectoryFixtureExporter: Sendable {
  public struct Configuration: Sendable {
    public var prettyPrinted: Bool
    public var preservesNativeIdentifiers: Bool

    public init(
      prettyPrinted: Bool = true,
      preservesNativeIdentifiers: Bool = false
    ) {
      self.prettyPrinted = prettyPrinted
      self.preservesNativeIdentifiers = preservesNativeIdentifiers
    }

    public static let `default` = Configuration()
  }

  public init() {}

  public func data(
    for trajectory: FoundationModelsAgentTrajectory,
    named name: String,
    expectedDestination: String? = nil,
    configuration: Configuration = .default
  ) throws -> Data {
    let stableTrajectory =
      configuration.preservesNativeIdentifiers
      ? trajectory
      : trajectory.replacingIdentifiersForFixture()
    let fixture = FoundationModelsAgentTrajectoryFixture(
      name: name,
      expectedDestination: expectedDestination,
      trajectory: stableTrajectory
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting =
      configuration.prettyPrinted
      ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      : [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(fixture)
  }

  public func write(
    _ trajectory: FoundationModelsAgentTrajectory,
    named name: String,
    expectedDestination: String? = nil,
    to url: URL,
    configuration: Configuration = .default
  ) throws {
    try data(
      for: trajectory,
      named: name,
      expectedDestination: expectedDestination,
      configuration: configuration
    ).write(to: url, options: .atomic)
  }

  public func decode(_ data: Data) throws -> FoundationModelsAgentTrajectoryFixture {
    try JSONDecoder().decode(FoundationModelsAgentTrajectoryFixture.self, from: data)
  }
}

extension FoundationModelsAgentTrajectory {
  private struct Builder {
    let run: FoundationModelsAgentRun?
    let redactionPolicy: FoundationModelsAgentRedactionPolicy
    let sensitiveArgumentNames: Set<String>
    var steps: [Step] = []
    var issues: [Issue] = []
    var callNamesByID: [String: String] = [:]
    var callStepIndicesByID: [String: Int] = [:]
    var duplicateCallIDs: Set<String> = []

    mutating func append(transcript: Transcript) {
      for entry in transcript {
        switch entry {
        case .instructions(let instructions):
          appendEntry(
            id: instructions.id,
            kind: .instructions,
            segments: instructions.segments
          )

        case .prompt(let prompt):
          appendEntry(id: prompt.id, kind: .prompt, segments: prompt.segments)

        case .toolCalls(let calls):
          steps.append(
            Step(sequence: steps.count, id: calls.id, kind: .toolCallGroup)
          )
          if calls.isEmpty {
            issues.append(
              Issue(
                kind: .emptyToolCallGroup,
                entryID: calls.id,
                detail: "The native tool-call group contains no calls."
              )
            )
          }
          for call in calls {
            append(call: call, parentID: calls.id)
          }

        case .toolOutput(let output):
          append(output: output)

        case .response(let response):
          appendEntry(id: response.id, kind: .response, segments: response.segments)

        case .reasoning(let reasoning):
          appendEntry(id: reasoning.id, kind: .reasoning, segments: reasoning.segments)

        @unknown default:
          issues.append(
            Issue(
              kind: .unsupportedTranscriptEntry,
              entryID: entry.id,
              detail: "This native transcript entry kind is not supported by this exporter."
            )
          )
          steps.append(
            Step(sequence: steps.count, id: entry.id, kind: .unsupported)
          )
        }
      }

      applyRunOutcomes()
      markUnmatchedCalls()
    }

    mutating func appendEntry(
      id: String,
      kind: Step.Kind,
      segments: [Transcript.Segment]
    ) {
      steps.append(
        Step(
          sequence: steps.count,
          id: id,
          kind: kind,
          segments: convertedSegments(segments, entryID: id)
        )
      )
    }

    mutating func append(call: Transcript.ToolCall, parentID: String) {
      if callNamesByID[call.id] == nil {
        callNamesByID[call.id] = call.toolName
      } else {
        duplicateCallIDs.insert(call.id)
        issues.append(
          Issue(
            kind: .duplicateToolCallID,
            entryID: call.id,
            detail: "More than one native tool call uses this ID."
          )
        )
      }

      let canonicalArgumentsJSON: String?
      do {
        let value = try StableJSONValue.decode(call.arguments.jsonString)
        guard case .object = value else {
          throw StableJSONError.argumentsMustBeObject
        }
        canonicalArgumentsJSON =
          try value
          .redacting(
            sensitiveKeys: sensitiveArgumentNames,
            redactionPolicy: redactionPolicy
          )
          .canonicalString()
      } catch {
        canonicalArgumentsJSON = redactionPolicy.redact(call.arguments.jsonString)
        issues.append(
          Issue(
            kind: .malformedToolArguments,
            entryID: call.id,
            detail: "Tool arguments were not a canonical JSON object: \(error)"
          )
        )
      }

      let index = steps.count
      steps.append(
        Step(
          sequence: index,
          id: call.id,
          parentID: parentID,
          kind: .toolCall,
          toolName: call.toolName,
          canonicalArgumentsJSON: canonicalArgumentsJSON,
          toolOutcome: .incomplete
        )
      )
      if callStepIndicesByID[call.id] == nil {
        callStepIndicesByID[call.id] = index
      }
    }

    mutating func append(output: Transcript.ToolOutput) {
      let parentID: String?
      if duplicateCallIDs.contains(output.id) {
        parentID = nil
        issues.append(
          Issue(
            kind: .ambiguousToolOutputLinkage,
            entryID: output.id,
            detail:
              "More than one native tool call has this output ID, so no parent or outcome was inferred."
          )
        )
      } else if let callName = callNamesByID[output.id] {
        parentID = output.id
        if callName != output.toolName {
          issues.append(
            Issue(
              kind: .toolNameMismatch,
              entryID: output.id,
              detail:
                "Tool output names '\(output.toolName)' but the matching call names '\(callName)'."
            )
          )
        }
        if let callIndex = callStepIndicesByID[output.id] {
          replaceToolOutcome(at: callIndex, with: .succeeded)
        }
      } else {
        parentID = nil
        issues.append(
          Issue(
            kind: .orphanedToolOutput,
            entryID: output.id,
            detail: "No preceding native tool call has this output ID."
          )
        )
      }

      steps.append(
        Step(
          sequence: steps.count,
          id: output.id,
          parentID: parentID,
          kind: .toolOutput,
          toolName: output.toolName,
          segments: convertedSegments(output.segments, entryID: output.id)
        )
      )
    }

    mutating func convertedSegments(
      _ segments: [Transcript.Segment],
      entryID: String
    ) -> [Segment] {
      segments.map { segment in
        switch segment {
        case .text(let text):
          return Segment(
            id: text.id,
            kind: .text,
            text: redactionPolicy.redact(text.content)
          )

        case .structure(let structure):
          let canonical = try? StableJSONValue.decode(structure.content.jsonString)
            .redacting(
              sensitiveKeys: sensitiveArgumentNames,
              redactionPolicy: redactionPolicy
            )
            .canonicalString()
          return Segment(
            id: structure.id,
            kind: .structure,
            schemaName: structure.schemaName,
            canonicalContentJSON: canonical
              ?? redactionPolicy.redact(structure.content.jsonString)
          )

        case .attachment(let attachment):
          issues.append(
            Issue(
              kind: .unsupportedAttachment,
              entryID: entryID,
              detail: "An attachment segment is recorded but not serialized."
            )
          )
          return Segment(
            id: attachment.id,
            kind: .unsupportedAttachment,
            unsupportedType: "FoundationModels.Transcript.Attachment"
          )

        case .custom(let custom):
          let typeName = String(reflecting: Swift.type(of: custom))
          issues.append(
            Issue(
              kind: .unsupportedCustomSegment,
              entryID: entryID,
              detail:
                "A custom segment of type '\(typeName)' requires provider-specific export."
            )
          )
          return Segment(
            id: custom.id,
            kind: .unsupportedCustom,
            unsupportedType: typeName
          )

        @unknown default:
          issues.append(
            Issue(
              kind: .unsupportedTranscriptSegment,
              entryID: entryID,
              detail: "A native segment has an unsupported future kind."
            )
          )
          return Segment(
            id: segment.id,
            kind: .unsupported,
            unsupportedType: "FoundationModels.Transcript.Segment"
          )
        }
      }
    }

    mutating func markUnmatchedCalls() {
      let matchedIDs = Set(
        steps.compactMap { step in
          step.kind == .toolOutput ? step.parentID : nil
        }
      )
      let ambiguousIDs = Set(
        issues.compactMap { issue in
          issue.kind == .ambiguousToolOutcome ? issue.entryID : nil
        }
      )
      for call in steps where call.kind == .toolCall && !matchedIDs.contains(call.id) {
        if [.denied, .cancelled, .failed].contains(call.toolOutcome) {
          continue
        }
        let kind: Issue.Kind =
          run == nil || ambiguousIDs.contains(call.id)
          ? .unresolvedToolCall
          : .orphanedToolCall
        issues.append(
          Issue(
            kind: kind,
            entryID: call.id,
            detail:
              kind == .orphanedToolCall
              ? "Audited run evidence exists, but the native transcript has no matching tool output."
              : "No native tool output or unambiguous audited outcome matches this call ID."
          )
        )
      }
    }

    mutating func applyRunOutcomes() {
      guard let run else { return }
      var outcomesByToolName: [String: [Step.ToolOutcome]] = [:]
      for event in run.events {
        guard let toolName = event.attributes["tool"] else { continue }
        let outcome: Step.ToolOutcome?
        switch event.kind {
        case .toolAuthorizationDenied:
          outcome = .denied
        case .toolAuthorizationCancelled:
          outcome = .cancelled
        case .toolAuthorizationFailed, .toolExecutionFailed:
          outcome = .failed
        case .toolExecutionCompleted:
          outcome = .succeeded
        default:
          outcome = nil
        }
        if let outcome {
          outcomesByToolName[toolName, default: []].append(outcome)
        }
      }

      var callIndicesByToolName: [String: [Int]] = [:]
      var toolNamesInTranscriptOrder: [String] = []
      for index in steps.indices where steps[index].kind == .toolCall {
        if let toolName = steps[index].toolName {
          if callIndicesByToolName[toolName] == nil {
            toolNamesInTranscriptOrder.append(toolName)
          }
          callIndicesByToolName[toolName, default: []].append(index)
        }
      }

      for toolName in toolNamesInTranscriptOrder {
        guard let indices = callIndicesByToolName[toolName] else { continue }
        let outcomes = outcomesByToolName[toolName, default: []]
        guard !outcomes.isEmpty else { continue }
        let unresolved = indices.filter { steps[$0].toolOutcome == .incomplete }
        let unsuccessful = outcomes.filter { $0 != .succeeded }

        if indices.count == 1 {
          let index = indices[0]
          if steps[index].toolOutcome == .incomplete, let outcome = outcomes.last {
            replaceToolOutcome(at: index, with: outcome)
          } else if !unsuccessful.isEmpty {
            appendAmbiguousOutcomeIssue(
              at: index,
              detail:
                "Audited run outcome conflicts with the native tool output for '\(toolName)'."
            )
          }
          continue
        }

        if unresolved.count == 1, unsuccessful.count == 1 {
          replaceToolOutcome(at: unresolved[0], with: unsuccessful[0])
          continue
        }

        if unresolved.isEmpty {
          if !unsuccessful.isEmpty, let index = indices.first {
            appendAmbiguousOutcomeIssue(
              at: index,
              detail:
                "Audited run outcome conflicts with native outputs for repeated '\(toolName)' calls."
            )
          }
          continue
        }

        for index in unresolved {
          appendAmbiguousOutcomeIssue(
            at: index,
            detail:
              "Repeated '\(toolName)' calls cannot be correlated losslessly with name-only audited outcomes."
          )
        }
      }
    }

    mutating func appendAmbiguousOutcomeIssue(at index: Int, detail: String) {
      issues.append(
        Issue(
          kind: .ambiguousToolOutcome,
          entryID: steps[index].id,
          detail: detail
        )
      )
    }

    mutating func replaceToolOutcome(at index: Int, with outcome: Step.ToolOutcome) {
      let step = steps[index]
      steps[index] = Step(
        sequence: step.sequence,
        id: step.id,
        parentID: step.parentID,
        kind: step.kind,
        toolName: step.toolName,
        canonicalArgumentsJSON: step.canonicalArgumentsJSON,
        toolOutcome: outcome,
        segments: step.segments
      )
    }

    func trajectory() -> FoundationModelsAgentTrajectory {
      FoundationModelsAgentTrajectory(
        runID: run?.id,
        finalStatus: run.map(Self.finalStatus) ?? .incomplete,
        steps: steps,
        issues: issues
      )
    }

    static func finalStatus(_ run: FoundationModelsAgentRun) -> FinalStatus {
      if run.events.contains(where: { $0.kind == .runCompleted }) {
        return .completed
      }
      if run.events.contains(where: { $0.kind == .runFailed }) {
        return .failed
      }
      return .incomplete
    }
  }

  fileprivate func replacingIdentifiersForFixture() -> Self {
    let stableStepIDs = steps.indices.map {
      "step-\(String(format: "%04d", $0))"
    }
    var referenceIDs: [String: String] = [:]
    for (index, step) in steps.enumerated() {
      if referenceIDs[step.id] == nil {
        referenceIDs[step.id] = stableStepIDs[index]
      }
    }
    var externalParentIndex = 0
    for parentID in steps.compactMap(\.parentID) where referenceIDs[parentID] == nil {
      referenceIDs[parentID] =
        "parent-\(String(format: "%04d", externalParentIndex))"
      externalParentIndex += 1
    }

    let stableSteps = steps.enumerated().map { index, step in
      Step(
        sequence: step.sequence,
        id: stableStepIDs[index],
        parentID: step.parentID.map { referenceIDs[$0] ?? $0 },
        kind: step.kind,
        toolName: step.toolName,
        canonicalArgumentsJSON: step.canonicalArgumentsJSON,
        toolOutcome: step.toolOutcome,
        segments: step.segments.enumerated().map { segmentIndex, segment in
          Segment(
            id:
              "step-\(String(format: "%04d", index))-segment-\(String(format: "%04d", segmentIndex))",
            kind: segment.kind,
            text: segment.text,
            schemaName: segment.schemaName,
            canonicalContentJSON: segment.canonicalContentJSON,
            unsupportedType: segment.unsupportedType
          )
        }
      )
    }
    let stableIssues = issues.map { issue in
      Issue(
        kind: issue.kind,
        entryID: referenceIDs[issue.entryID] ?? issue.entryID,
        detail: issue.detail
      )
    }
    return Self(
      runID: nil,
      finalStatus: finalStatus,
      steps: stableSteps,
      issues: stableIssues
    )
  }
}

private enum StableJSONError: Error, CustomStringConvertible {
  case invalidUTF8
  case argumentsMustBeObject

  var description: String {
    switch self {
    case .invalidUTF8:
      "Canonical JSON was not UTF-8."
    case .argumentsMustBeObject:
      "Tool arguments must be a JSON object."
    }
  }
}

private indirect enum StableJSONValue: Codable, Equatable, Sendable {
  case string(String)
  case integer(Int64)
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
    } else if let value = try? container.decode(Int64.self) {
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

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .integer(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .boolean(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  static func decode(_ string: String) throws -> Self {
    try JSONDecoder().decode(Self.self, from: Data(string.utf8))
  }

  func canonicalString() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard let value = String(data: data, encoding: .utf8) else {
      throw StableJSONError.invalidUTF8
    }
    return value
  }

  func redacting(
    sensitiveKeys: Set<String>,
    redactionPolicy: FoundationModelsAgentRedactionPolicy
  ) -> Self {
    switch self {
    case .string(let value):
      return .string(redactionPolicy.redact(value))
    case .array(let values):
      return .array(
        values.map {
          $0.redacting(sensitiveKeys: sensitiveKeys, redactionPolicy: redactionPolicy)
        }
      )
    case .object(let values):
      var redacted: [String: Self] = [:]
      redacted.reserveCapacity(values.count)
      for (key, value) in values {
        redacted[key] =
          sensitiveKeys.contains(key.lowercased())
          ? .string("[REDACTED]")
          : value.redacting(
            sensitiveKeys: sensitiveKeys,
            redactionPolicy: redactionPolicy
          )
      }
      return .object(redacted)
    default:
      return self
    }
  }
}
