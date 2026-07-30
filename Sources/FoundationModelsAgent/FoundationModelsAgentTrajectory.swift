import Foundation
import FoundationModels

/// A stable, framework-independent record of the path an agent took through a native transcript.
///
/// `FoundationModelsAgentTrajectory` keeps Foundation Models as the runtime source of truth while
/// making observed tool calls and destination content suitable for deterministic regression
/// fixtures. It deliberately does not define a second transcript or message API.
public struct FoundationModelsAgentTrajectory: Codable, Equatable, Sendable {
  public static let currentFormatVersion = 2

  public enum FinalStatus: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
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

    public enum ToolOutcome: String, Codable, Equatable, Hashable, Sendable {
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
      case ambiguousRootRun
      case ambiguousToolOutputLinkage
      case ambiguousToolOutcome
      case duplicateToolCallID
      case emptyToolCallGroup
      case malformedToolArguments
      case missingNativeTranscript
      case orphanedToolCall
      case orphanedToolOutput
      case toolNameMismatch
      case unsupportedAttachment
      case unsupportedCustomSegment
      case unsupportedTranscriptEntry
      case unsupportedTranscriptSegment
      case transcriptWithoutEvidence
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

  /// A stable projection of the package's canonical, verified execution-evidence graph.
  ///
  /// The projection keeps only evaluation-relevant lineage, terminal settlement, event, and
  /// reference data. It does not replace ``AgentReceiptBundle``: callers construct this value
  /// through the validating trajectory initializer, and should continue to verify or archive the
  /// original bundle when tamper evidence matters.
  public struct EvidenceGraph: Codable, Equatable, Sendable {
    public struct Lineage: Codable, Equatable, Sendable {
      public let runID: String
      public let rootRunID: String
      public let parentRunID: String?
      public let taskID: String?
      public let depth: Int
      public let relationship: AgentRunRelationshipKind

      public init(
        runID: String,
        rootRunID: String,
        parentRunID: String?,
        taskID: String?,
        depth: Int,
        relationship: AgentRunRelationshipKind
      ) {
        self.runID = runID
        self.rootRunID = rootRunID
        self.parentRunID = parentRunID
        self.taskID = taskID
        self.depth = depth
        self.relationship = relationship
      }
    }

    public struct Event: Codable, Equatable, Sendable {
      public let id: String
      public let runID: String
      public let kind: FoundationModelsAgentEventKind
      public let attributes: [String: String]

      public init(
        id: String,
        runID: String,
        kind: FoundationModelsAgentEventKind,
        attributes: [String: String] = [:]
      ) {
        self.id = id
        self.runID = runID
        self.kind = kind
        self.attributes = attributes
      }
    }

    public struct Reference: Codable, Equatable, Sendable {
      public let id: String
      public let kind: String
      public let runID: String?
      public let eventID: String?
      public let location: String?
      public let attributes: [String: String]

      public init(
        id: String,
        kind: String,
        runID: String? = nil,
        eventID: String? = nil,
        location: String? = nil,
        attributes: [String: String] = [:]
      ) {
        self.id = id
        self.kind = kind
        self.runID = runID
        self.eventID = eventID
        self.location = location
        self.attributes = attributes
      }
    }

    public struct Run: Codable, Equatable, Sendable {
      public let runID: String
      public let lineage: Lineage?
      public let finalStatus: FinalStatus
      public let steps: [Step]
      public let events: [Event]
      public let issues: [Issue]

      public init(
        runID: String,
        lineage: Lineage?,
        finalStatus: FinalStatus,
        steps: [Step],
        events: [Event],
        issues: [Issue] = []
      ) {
        self.runID = runID
        self.lineage = lineage
        self.finalStatus = finalStatus
        self.steps = steps
        self.events = events
        self.issues = issues
      }
    }

    public struct Task: Codable, Equatable, Sendable {
      public let lineage: Lineage
      public let status: AgentTaskSettlementStatus
      public let outputReferences: [Reference]
      public let evidenceReferences: [Reference]
      public let failureReason: AgentTaskSettlementReason?
      public let cancellationReason: AgentTaskSettlementReason?

      public init(
        lineage: Lineage,
        status: AgentTaskSettlementStatus,
        outputReferences: [Reference] = [],
        evidenceReferences: [Reference] = [],
        failureReason: AgentTaskSettlementReason? = nil,
        cancellationReason: AgentTaskSettlementReason? = nil
      ) {
        self.lineage = lineage
        self.status = status
        self.outputReferences = outputReferences
        self.evidenceReferences = evidenceReferences
        self.failureReason = failureReason
        self.cancellationReason = cancellationReason
      }
    }

    public let runs: [Run]
    public let tasks: [Task]

    public init(runs: [Run], tasks: [Task] = []) {
      self.runs = runs
      self.tasks = tasks
    }
  }

  public let formatVersion: Int
  public let runID: UUID?
  public let finalStatus: FinalStatus
  public let steps: [Step]
  public let issues: [Issue]
  public let evidenceGraph: EvidenceGraph?

  private enum CodingKeys: String, CodingKey {
    case formatVersion
    case runID
    case finalStatus
    case steps
    case issues
    case evidenceGraph
  }

  public init(
    formatVersion: Int = Self.currentFormatVersion,
    runID: UUID? = nil,
    finalStatus: FinalStatus,
    steps: [Step],
    issues: [Issue] = [],
    evidenceGraph: EvidenceGraph? = nil
  ) {
    self.formatVersion = formatVersion
    self.runID = runID
    self.finalStatus = finalStatus
    self.steps = steps
    self.issues = issues
    self.evidenceGraph = evidenceGraph
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      formatVersion: try container.decode(Int.self, forKey: .formatVersion),
      runID: try container.decodeIfPresent(UUID.self, forKey: .runID),
      finalStatus: try container.decode(FinalStatus.self, forKey: .finalStatus),
      steps: try container.decode([Step].self, forKey: .steps),
      issues: try container.decodeIfPresent([Issue].self, forKey: .issues) ?? [],
      evidenceGraph: try container.decodeIfPresent(EvidenceGraph.self, forKey: .evidenceGraph)
    )
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

  /// Builds a multi-run trajectory from a verified canonical evidence graph.
  ///
  /// Each supplied transcript is associated only through its canonical `AgentRunID`. Descendant
  /// runs without a supplied transcript remain in `evidenceGraph.runs` with an explicit
  /// `missingNativeTranscript` issue. Receipt and task linkage is verified before conversion, so
  /// this initializer never guesses parent, child, routing, context, or evidence relationships.
  public init(
    transcripts: [AgentRunID: Transcript],
    evidenceBundle: AgentReceiptBundle,
    redactionPolicy: FoundationModelsAgentRedactionPolicy = .standard,
    sensitiveArgumentNames: Set<String> = Self.defaultSensitiveArgumentNames
  ) throws {
    try evidenceBundle.verify()
    self = Self(
      verifiedTranscripts: transcripts,
      evidenceBundle: evidenceBundle,
      redactionPolicy: redactionPolicy,
      sensitiveArgumentNames: sensitiveArgumentNames
    )
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
  public static let currentFormatVersion = 2

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

  public func decode(contentsOf url: URL) throws -> FoundationModelsAgentTrajectoryFixture {
    try decode(Data(contentsOf: url))
  }
}

extension FoundationModelsAgentTrajectory {
  private struct Builder {
    let run: FoundationModelsAgentRun?
    let evidenceEvents: [FoundationModelsAgentEvent]
    let redactionPolicy: FoundationModelsAgentRedactionPolicy
    let sensitiveArgumentNames: Set<String>
    var steps: [Step] = []
    var issues: [Issue] = []
    var callNamesByID: [String: String] = [:]
    var callStepIndicesByID: [String: Int] = [:]
    var duplicateCallIDs: Set<String> = []

    init(
      run: FoundationModelsAgentRun?,
      evidenceEvents: [FoundationModelsAgentEvent]? = nil,
      redactionPolicy: FoundationModelsAgentRedactionPolicy,
      sensitiveArgumentNames: Set<String>
    ) {
      self.run = run
      self.evidenceEvents = evidenceEvents ?? run?.events ?? []
      self.redactionPolicy = redactionPolicy
      self.sensitiveArgumentNames = sensitiveArgumentNames
    }

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

      applyEvidenceOutcomes()
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
          evidenceEvents.isEmpty || ambiguousIDs.contains(call.id)
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

    mutating func applyEvidenceOutcomes() {
      guard !evidenceEvents.isEmpty else { return }
      var outcomesByCallID: [String: [Step.ToolOutcome]] = [:]
      var outcomesByToolName: [String: [Step.ToolOutcome]] = [:]
      for event in evidenceEvents {
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
          if let callID = event.attributes["native_call_id"] {
            outcomesByCallID[callID, default: []].append(outcome)
          } else {
            outcomesByToolName[toolName, default: []].append(outcome)
          }
        }
      }

      for (callID, outcomes) in outcomesByCallID.sorted(by: { $0.key < $1.key }) {
        guard !duplicateCallIDs.contains(callID),
          let index = callStepIndicesByID[callID]
        else {
          continue
        }
        let distinct = Set(outcomes)
        guard distinct.count == 1, let outcome = outcomes.last else {
          appendAmbiguousOutcomeIssue(
            at: index,
            detail: "Canonical evidence contains conflicting outcomes for native call '\(callID)'."
          )
          continue
        }
        if steps[index].toolOutcome == .incomplete {
          replaceToolOutcome(at: index, with: outcome)
        } else if steps[index].toolOutcome != outcome {
          appendAmbiguousOutcomeIssue(
            at: index,
            detail:
              "Canonical evidence conflicts with the native transcript outcome for call '\(callID)'; the native transcript remains authoritative."
          )
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
          let distinct = Set(outcomes)
          guard distinct.count == 1, let outcome = outcomes.last else {
            appendAmbiguousOutcomeIssue(
              at: index,
              detail:
                "Name-only audited evidence contains conflicting outcomes for '\(toolName)'."
            )
            continue
          }
          if steps[index].toolOutcome == .incomplete {
            replaceToolOutcome(at: index, with: outcome)
          } else if steps[index].toolOutcome != outcome {
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
      finalStatus(run.events)
    }

    static func finalStatus(_ events: [FoundationModelsAgentEvent]) -> FinalStatus {
      if events.contains(where: { $0.kind == .runCompleted }) { return .completed }
      if events.contains(where: { $0.kind == .runCancelled }) { return .cancelled }
      if events.contains(where: { $0.kind == .runFailed }) { return .failed }
      return .incomplete
    }
  }

  private init(
    verifiedTranscripts transcripts: [AgentRunID: Transcript],
    evidenceBundle: AgentReceiptBundle,
    redactionPolicy: FoundationModelsAgentRedactionPolicy,
    sensitiveArgumentNames: Set<String>
  ) {
    let orderedReceipts = evidenceBundle.receipts.sorted { lhs, rhs in
      let lhsDepth = lhs.lineage?.depth.rawValue ?? 0
      let rhsDepth = rhs.lineage?.depth.rawValue ?? 0
      if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
      return lhs.runID.uuidString < rhs.runID.uuidString
    }
    let evidencedRunIDs = Set(orderedReceipts.map { AgentRunID(rawValue: $0.runID) })
    var graphRuns: [EvidenceGraph.Run] = []
    var allIssues: [Issue] = []

    for receipt in orderedReceipts {
      let runID = AgentRunID(rawValue: receipt.runID)
      let events = receipt.receipts.map(\.event)
      var steps: [Step] = []
      var runIssues: [Issue] = []
      if let transcript = transcripts[runID] {
        var builder = Builder(
          run: nil,
          evidenceEvents: events,
          redactionPolicy: redactionPolicy,
          sensitiveArgumentNames: sensitiveArgumentNames
        )
        builder.append(transcript: transcript)
        steps = builder.steps
        runIssues = builder.issues
      } else {
        runIssues = [
          Issue(
            kind: .missingNativeTranscript,
            entryID: runID.description,
            detail:
              "Canonical run evidence exists, but no native transcript was supplied for this run."
          )
        ]
      }
      allIssues.append(contentsOf: runIssues)
      graphRuns.append(
        EvidenceGraph.Run(
          runID: runID.description,
          lineage: receipt.lineage.map(Self.project),
          finalStatus: Builder.finalStatus(events),
          steps: steps,
          events: events.map {
            EvidenceGraph.Event(
              id: $0.id.uuidString.lowercased(),
              runID: AgentRunID(rawValue: $0.runID).description,
              kind: $0.kind,
              attributes: redactionPolicy.redact(attributes: $0.attributes)
            )
          },
          issues: runIssues
        )
      )
    }

    for runID in transcripts.keys.sorted(by: { $0.description < $1.description })
    where !evidencedRunIDs.contains(runID) {
      allIssues.append(
        Issue(
          kind: .transcriptWithoutEvidence,
          entryID: runID.description,
          detail:
            "A native transcript was supplied for a run absent from the canonical evidence graph."
        )
      )
    }

    let runOrder = Dictionary(
      uniqueKeysWithValues: graphRuns.enumerated().map { ($0.element.runID, $0.offset) }
    )
    let tasks = evidenceBundle.taskResults
      .sorted {
        let lhsOrder = runOrder[$0.lineage.runID.description] ?? Int.max
        let rhsOrder = runOrder[$1.lineage.runID.description] ?? Int.max
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        return ($0.lineage.taskID?.description ?? "") < ($1.lineage.taskID?.description ?? "")
      }
      .map { result in
        EvidenceGraph.Task(
          lineage: Self.project(result.lineage),
          status: result.status,
          outputReferences: result.outputReferences.map {
            Self.project($0, redactionPolicy: redactionPolicy)
          },
          evidenceReferences: result.evidenceReferences.map {
            Self.project($0, redactionPolicy: redactionPolicy)
          },
          failureReason: result.failureReason.map {
            AgentTaskSettlementReason(
              code: redactionPolicy.redact($0.code),
              message: redactionPolicy.redact($0.message)
            )
          },
          cancellationReason: result.cancellationReason.map {
            AgentTaskSettlementReason(
              code: redactionPolicy.redact($0.code),
              message: redactionPolicy.redact($0.message)
            )
          }
        )
      }

    let roots = graphRuns.filter {
      $0.lineage?.relationship == .root || $0.lineage == nil
    }
    let primary = roots.count == 1 ? roots[0] : nil
    if primary == nil {
      allIssues.append(
        Issue(
          kind: .ambiguousRootRun,
          entryID: "evidence-graph",
          detail:
            "The canonical evidence bundle does not contain exactly one root run, so no primary trajectory was inferred."
        )
      )
    }
    self.init(
      runID: primary.flatMap { UUID(uuidString: $0.runID) },
      finalStatus: primary?.finalStatus ?? .incomplete,
      steps: primary?.steps ?? [],
      issues: allIssues,
      evidenceGraph: EvidenceGraph(runs: graphRuns, tasks: tasks)
    )
  }

  private static func project(_ lineage: AgentRunLineage) -> EvidenceGraph.Lineage {
    EvidenceGraph.Lineage(
      runID: lineage.runID.description,
      rootRunID: lineage.rootRunID.description,
      parentRunID: lineage.parentRunID?.description,
      taskID: lineage.taskID?.description,
      depth: lineage.depth.rawValue,
      relationship: lineage.relationship
    )
  }

  private static func project(
    _ reference: AgentEvidenceReference,
    redactionPolicy: FoundationModelsAgentRedactionPolicy
  ) -> EvidenceGraph.Reference {
    EvidenceGraph.Reference(
      id: redactionPolicy.redact(reference.id.rawValue),
      kind: redactionPolicy.redact(reference.kind.rawValue),
      runID: reference.runID?.description,
      eventID: reference.eventID?.uuidString.lowercased(),
      location: reference.location.map(redactionPolicy.redact),
      attributes: redactionPolicy.redact(attributes: reference.attributes)
    )
  }

  fileprivate func replacingIdentifiersForFixture() -> Self {
    let (stableSteps, primaryStepIDs) = Self.stableSteps(steps)
    guard let evidenceGraph else {
      return Self(
        runID: nil,
        finalStatus: finalStatus,
        steps: stableSteps,
        issues: issues.map {
          Issue(
            kind: $0.kind,
            entryID: primaryStepIDs[$0.entryID] ?? $0.entryID,
            detail: Self.replacingIdentifierOccurrences(
              $0.detail,
              identifiers: primaryStepIDs
            )
          )
        }
      )
    }

    let runIDs = Dictionary(
      uniqueKeysWithValues: evidenceGraph.runs.enumerated().map {
        ($0.element.runID, "run-\(String(format: "%04d", $0.offset))")
      }
    )
    let taskIDs = Dictionary(
      uniqueKeysWithValues: evidenceGraph.tasks.enumerated().compactMap { index, task in
        task.lineage.taskID.map { ($0, "task-\(String(format: "%04d", index))") }
      }
    )
    var eventIDs: [String: String] = [:]
    for (runIndex, run) in evidenceGraph.runs.enumerated() {
      for (eventIndex, event) in run.events.enumerated() {
        eventIDs[event.id] =
          "run-\(String(format: "%04d", runIndex))-event-\(String(format: "%04d", eventIndex))"
      }
    }
    let graphIdentifierIDs = runIDs.merging(taskIDs) { current, _ in current }
      .merging(eventIDs) { current, _ in current }
    let stableRuns = evidenceGraph.runs.enumerated().map { runIndex, run in
      let (runSteps, stepIDs) = Self.stableSteps(run.steps)
      let identifierIDs = graphIdentifierIDs.merging(stepIDs) { current, _ in current }
      return EvidenceGraph.Run(
        runID: runIDs[run.runID]!,
        lineage: run.lineage.map {
          Self.stableLineage($0, runIDs: runIDs, taskIDs: taskIDs)
        },
        finalStatus: run.finalStatus,
        steps: runSteps,
        events: run.events.enumerated().map { eventIndex, event in
          EvidenceGraph.Event(
            id:
              "run-\(String(format: "%04d", runIndex))-event-\(String(format: "%04d", eventIndex))",
            runID: runIDs[event.runID] ?? event.runID,
            kind: event.kind,
            attributes: Self.replacingIdentifierAttributeValues(
              event.attributes,
              identifiers: identifierIDs
            )
          )
        },
        issues: run.issues.map {
          Issue(
            kind: $0.kind,
            entryID: identifierIDs[$0.entryID] ?? $0.entryID,
            detail: Self.replacingIdentifierOccurrences(
              $0.detail,
              identifiers: identifierIDs
            )
          )
        }
      )
    }
    var referenceIndex = 0
    func stableReferences(_ references: [EvidenceGraph.Reference]) -> [EvidenceGraph.Reference] {
      references.map { reference in
        defer { referenceIndex += 1 }
        return EvidenceGraph.Reference(
          id: "reference-\(String(format: "%04d", referenceIndex))",
          kind: reference.kind,
          runID: reference.runID.map { runIDs[$0] ?? $0 },
          eventID: reference.eventID.map { eventIDs[$0] ?? $0 },
          location: reference.location.map {
            Self.replacingIdentifierOccurrences($0, identifiers: graphIdentifierIDs)
          },
          attributes: Self.replacingIdentifierAttributeValues(
            reference.attributes,
            identifiers: graphIdentifierIDs
          )
        )
      }
    }
    let stableTasks = evidenceGraph.tasks.map { task in
      EvidenceGraph.Task(
        lineage: Self.stableLineage(task.lineage, runIDs: runIDs, taskIDs: taskIDs),
        status: task.status,
        outputReferences: stableReferences(task.outputReferences),
        evidenceReferences: stableReferences(task.evidenceReferences),
        failureReason: task.failureReason.map {
          AgentTaskSettlementReason(
            code: Self.replacingIdentifierOccurrences(
              $0.code,
              identifiers: graphIdentifierIDs
            ),
            message: Self.replacingIdentifierOccurrences(
              $0.message,
              identifiers: graphIdentifierIDs
            )
          )
        },
        cancellationReason: task.cancellationReason.map {
          AgentTaskSettlementReason(
            code: Self.replacingIdentifierOccurrences(
              $0.code,
              identifiers: graphIdentifierIDs
            ),
            message: Self.replacingIdentifierOccurrences(
              $0.message,
              identifiers: graphIdentifierIDs
            )
          )
        }
      )
    }
    let allIdentifierIDs = graphIdentifierIDs.merging(primaryStepIDs) { current, _ in current }
    let stableIssues = issues.map { issue in
      Issue(
        kind: issue.kind,
        entryID: allIdentifierIDs[issue.entryID] ?? issue.entryID,
        detail: Self.replacingIdentifierOccurrences(
          issue.detail,
          identifiers: allIdentifierIDs
        )
      )
    }
    return Self(
      runID: nil,
      finalStatus: finalStatus,
      steps: stableSteps,
      issues: stableIssues,
      evidenceGraph: EvidenceGraph(runs: stableRuns, tasks: stableTasks)
    )
  }

  private static func stableSteps(_ steps: [Step]) -> ([Step], [String: String]) {
    let stableStepIDs = steps.indices.map { "step-\(String(format: "%04d", $0))" }
    var identifiers: [String: String] = [:]
    for (index, step) in steps.enumerated() where identifiers[step.id] == nil {
      identifiers[step.id] = stableStepIDs[index]
    }
    var externalParentIndex = 0
    for parentID in steps.compactMap(\.parentID) where identifiers[parentID] == nil {
      identifiers[parentID] = "parent-\(String(format: "%04d", externalParentIndex))"
      externalParentIndex += 1
    }
    let stable = steps.enumerated().map { index, step in
      Step(
        sequence: step.sequence,
        id: stableStepIDs[index],
        parentID: step.parentID.map { identifiers[$0] ?? $0 },
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
    return (stable, identifiers)
  }

  private static func stableLineage(
    _ lineage: EvidenceGraph.Lineage,
    runIDs: [String: String],
    taskIDs: [String: String]
  ) -> EvidenceGraph.Lineage {
    EvidenceGraph.Lineage(
      runID: runIDs[lineage.runID] ?? lineage.runID,
      rootRunID: runIDs[lineage.rootRunID] ?? lineage.rootRunID,
      parentRunID: lineage.parentRunID.map { runIDs[$0] ?? $0 },
      taskID: lineage.taskID.map { taskIDs[$0] ?? $0 },
      depth: lineage.depth,
      relationship: lineage.relationship
    )
  }

  private static func replacingIdentifierAttributeValues(
    _ attributes: [String: String],
    identifiers: [String: String]
  ) -> [String: String] {
    attributes.mapValues {
      replacingIdentifierOccurrences($0, identifiers: identifiers)
    }
  }

  private static func replacingIdentifierOccurrences(
    _ value: String,
    identifiers: [String: String]
  ) -> String {
    identifiers.keys.sorted {
      if $0.count != $1.count { return $0.count > $1.count }
      return $0 < $1
    }.reduce(value) { result, identifier in
      result.replacingOccurrences(of: identifier, with: identifiers[identifier]!)
    }
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
