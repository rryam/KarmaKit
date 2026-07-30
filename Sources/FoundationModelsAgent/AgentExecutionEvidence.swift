import Foundation

/// A stable identifier for one native `AgentSession` run.
public struct AgentRunID: Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init() {
    self.rawValue = UUID()
  }

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  public var description: String {
    rawValue.uuidString.lowercased()
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(UUID.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A stable identifier for work requested from a child or background agent.
public struct AgentTaskID: Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init() {
    self.rawValue = UUID()
  }

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  public var description: String {
    rawValue.uuidString.lowercased()
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(UUID.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// The zero-based distance of a run from its root run.
public struct AgentRunDepth: Codable, Hashable, Sendable, Comparable {
  public let rawValue: Int

  public init(_ rawValue: Int) throws {
    guard rawValue >= 0 else {
      throw AgentExecutionEvidenceError.invalidDepth(rawValue)
    }
    self.init(validatedRawValue: rawValue)
  }

  private init(validatedRawValue: Int) {
    self.rawValue = validatedRawValue
  }

  public static let root = AgentRunDepth(validatedRawValue: 0)

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(Int.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// How a run is related to its parent.
public enum AgentRunRelationshipKind: String, Codable, Equatable, Sendable {
  case root
  case child
  case background
}

/// Immutable ancestry for a run.
///
/// `ChildAgentTool` and future background-task APIs construct this value before starting a
/// native `AgentSession` response. FoundationModelsAgent does not execute or schedule the child.
public struct AgentRunLineage: Codable, Hashable, Sendable {
  public let runID: AgentRunID
  public let rootRunID: AgentRunID
  public let parentRunID: AgentRunID?
  public let taskID: AgentTaskID?
  public let depth: AgentRunDepth
  public let relationship: AgentRunRelationshipKind

  public init(
    runID: AgentRunID,
    rootRunID: AgentRunID,
    parentRunID: AgentRunID?,
    taskID: AgentTaskID?,
    depth: AgentRunDepth,
    relationship: AgentRunRelationshipKind
  ) throws {
    switch relationship {
    case .root:
      guard runID == rootRunID, parentRunID == nil, taskID == nil, depth == .root else {
        throw AgentExecutionEvidenceError.invalidRootLineage
      }
    case .child, .background:
      guard runID != rootRunID,
        let parentRunID,
        parentRunID != runID,
        taskID != nil,
        depth > .root
      else {
        throw AgentExecutionEvidenceError.invalidDescendantLineage
      }
    }

    self.init(
      validatedRunID: runID,
      rootRunID: rootRunID,
      parentRunID: parentRunID,
      taskID: taskID,
      depth: depth,
      relationship: relationship
    )
  }

  private init(
    validatedRunID runID: AgentRunID,
    rootRunID: AgentRunID,
    parentRunID: AgentRunID?,
    taskID: AgentTaskID?,
    depth: AgentRunDepth,
    relationship: AgentRunRelationshipKind
  ) {
    self.runID = runID
    self.rootRunID = rootRunID
    self.parentRunID = parentRunID
    self.taskID = taskID
    self.depth = depth
    self.relationship = relationship
  }

  public static func root(runID: AgentRunID = AgentRunID()) -> Self {
    Self(
      validatedRunID: runID,
      rootRunID: runID,
      parentRunID: nil,
      taskID: nil,
      depth: .root,
      relationship: .root
    )
  }

  public func descendant(
    runID: AgentRunID = AgentRunID(),
    taskID: AgentTaskID = AgentTaskID(),
    relationship: AgentRunRelationshipKind = .child
  ) throws -> Self {
    guard relationship != .root, depth.rawValue < Int.max else {
      throw AgentExecutionEvidenceError.invalidDescendantLineage
    }
    return try Self(
      runID: runID,
      rootRunID: rootRunID,
      parentRunID: self.runID,
      taskID: taskID,
      depth: AgentRunDepth(depth.rawValue + 1),
      relationship: relationship
    )
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      runID: container.decode(AgentRunID.self, forKey: .runID),
      rootRunID: container.decode(AgentRunID.self, forKey: .rootRunID),
      parentRunID: container.decodeIfPresent(AgentRunID.self, forKey: .parentRunID),
      taskID: container.decodeIfPresent(AgentTaskID.self, forKey: .taskID),
      depth: container.decode(AgentRunDepth.self, forKey: .depth),
      relationship: container.decode(AgentRunRelationshipKind.self, forKey: .relationship)
    )
  }
}

public enum AgentExecutionEvidenceError: Error, LocalizedError, Equatable, Sendable {
  case invalidDepth(Int)
  case invalidRootLineage
  case invalidDescendantLineage
  case invalidTaskTiming
  case invalidTaskSettlement(AgentTaskSettlementStatus)
  case runLineageMismatch(AgentRunID)
  case duplicateRunID(AgentRunID)
  case missingLineage(AgentRunID)
  case orphanedRun(runID: AgentRunID, missingParentRunID: AgentRunID)
  case missingRoot(runID: AgentRunID, rootRunID: AgentRunID)
  case cycleDetected(AgentRunID)
  case inconsistentRoot(runID: AgentRunID)
  case inconsistentDepth(runID: AgentRunID)
  case maximumDepthExceeded(runID: AgentRunID, maximum: AgentRunDepth)
  case invalidReceipt(AgentRunID)
  case duplicateTaskID(AgentTaskID)
  case missingTaskReceipt(AgentTaskID)
  case taskReceiptMismatch(AgentTaskID)
  case duplicateEvidenceReferenceID(AgentEvidenceReferenceID)
  case missingEvidenceRun(referenceID: AgentEvidenceReferenceID, runID: AgentRunID)
  case missingEvidenceEvent(referenceID: AgentEvidenceReferenceID, eventID: UUID)
  case evidenceEventRunMismatch(referenceID: AgentEvidenceReferenceID)

  public var errorDescription: String? {
    switch self {
    case .invalidDepth(let depth):
      "Agent run depth must be zero or greater; received \(depth)."
    case .invalidRootLineage:
      "A root run must identify itself as root, have depth zero, and have no parent or task."
    case .invalidDescendantLineage:
      "A child or background run must have a distinct root, parent, task, and positive depth."
    case .invalidTaskTiming:
      "Agent task timing must be ordered queued, started, then ended."
    case .invalidTaskSettlement(let status):
      "Agent task settlement reasons are inconsistent with terminal status '\(status.rawValue)'."
    case .runLineageMismatch(let runID):
      "Run \(runID) does not match the lineage carried by its events or receipt."
    case .duplicateRunID(let runID):
      "Receipt bundle contains run \(runID) more than once."
    case .missingLineage(let runID):
      "Hierarchical receipt bundle is missing lineage for run \(runID)."
    case .orphanedRun(let runID, let parentRunID):
      "Run \(runID) references missing parent \(parentRunID)."
    case .missingRoot(let runID, let rootRunID):
      "Run \(runID) references missing root \(rootRunID)."
    case .cycleDetected(let runID):
      "Run \(runID) participates in a lineage cycle."
    case .inconsistentRoot(let runID):
      "Run \(runID) does not preserve its parent's root run."
    case .inconsistentDepth(let runID):
      "Run \(runID) is not exactly one level deeper than its parent."
    case .maximumDepthExceeded(let runID, let maximum):
      "Run \(runID) exceeds maximum depth \(maximum.rawValue)."
    case .invalidReceipt(let runID):
      "Run \(runID) has an invalid tamper-evident receipt."
    case .duplicateTaskID(let taskID):
      "Receipt bundle contains task \(taskID) more than once."
    case .missingTaskReceipt(let taskID):
      "Task \(taskID) references a run that is absent from the receipt bundle."
    case .taskReceiptMismatch(let taskID):
      "Task \(taskID) does not match its linked run receipt."
    case .duplicateEvidenceReferenceID(let referenceID):
      "Task result contains evidence reference '\(referenceID)' more than once."
    case .missingEvidenceRun(let referenceID, let runID):
      "Evidence reference '\(referenceID)' links to missing run \(runID)."
    case .missingEvidenceEvent(let referenceID, let eventID):
      "Evidence reference '\(referenceID)' links to missing event \(eventID)."
    case .evidenceEventRunMismatch(let referenceID):
      "Evidence reference '\(referenceID)' links an event to the wrong run."
    }
  }
}

/// A stable, application-defined identifier for an output or evidence attachment.
public struct AgentEvidenceReferenceID:
  RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible,
  ExpressibleByStringLiteral
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  public init(stringLiteral value: String) {
    self.init(value)
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(try container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// The canonical record an ``AgentEvidenceReference`` resolves to.
public struct AgentEvidenceReferenceKind:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  public init(stringLiteral value: String) {
    self.init(value)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(try container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  /// A complete ``FoundationModelsAgentRun`` trace record.
  public static let run = Self("run")
  /// The ``FoundationModelsAgentRouteDecision`` stored on a run trace.
  public static let routingDecision = Self("routing-decision")
  /// One ``FoundationModelsAgentEvent`` in a run receipt.
  public static let event = Self("event")
  /// Application-owned generated output.
  public static let output = Self("output")
  /// Another application-owned artifact.
  public static let artifact = Self("artifact")
}

/// A URI-like reference to output or supporting evidence.
///
/// The referenced content remains application-owned. The envelope does not introduce a message,
/// transcript, or provider abstraction.
public struct AgentEvidenceReference: Codable, Equatable, Sendable, Identifiable {
  public let id: AgentEvidenceReferenceID
  public let kind: AgentEvidenceReferenceKind
  /// The run containing canonical routing, context, tool, or lifecycle evidence.
  public let runID: AgentRunID?
  /// The event containing canonical context, tool, or lifecycle evidence.
  public let eventID: UUID?
  public let location: String?
  public let attributes: [String: String]

  public init(
    id: AgentEvidenceReferenceID,
    kind: AgentEvidenceReferenceKind,
    runID: AgentRunID? = nil,
    eventID: UUID? = nil,
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

  /// References the complete trace for a run.
  public static func run(_ runID: AgentRunID) -> Self {
    Self(
      id: AgentEvidenceReferenceID("run:\(runID)"),
      kind: .run,
      runID: runID
    )
  }

  /// References the canonical route decision already stored on a run trace.
  public static func routingDecision(for runID: AgentRunID) -> Self {
    Self(
      id: AgentEvidenceReferenceID("run:\(runID):routing-decision"),
      kind: .routingDecision,
      runID: runID
    )
  }

  /// References a canonical run event without copying its routing, context, or tool attributes.
  public static func event(_ event: FoundationModelsAgentEvent) -> Self {
    let runID = AgentRunID(rawValue: event.runID)
    return Self(
      id: AgentEvidenceReferenceID("run:\(runID):event:\(event.id.uuidString.lowercased())"),
      kind: .event,
      runID: runID,
      eventID: event.id
    )
  }

  public func redacted(using policy: FoundationModelsAgentRedactionPolicy) -> Self {
    Self(
      id: AgentEvidenceReferenceID(policy.redact(id.rawValue)),
      kind: AgentEvidenceReferenceKind(policy.redact(kind.rawValue)),
      runID: runID,
      eventID: eventID,
      location: location.map(policy.redact),
      attributes: policy.redact(attributes: attributes)
    )
  }
}

/// A typed link from a task result to the tamper-evident receipt for its run.
public struct AgentReceiptReference: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let rootHash: String?

  public init(runID: AgentRunID, rootHash: String?) {
    self.runID = runID
    self.rootHash = rootHash
  }
}

public struct AgentTaskTiming: Codable, Equatable, Sendable {
  public let queuedAt: Date?
  public let startedAt: Date
  public let endedAt: Date

  public init(queuedAt: Date? = nil, startedAt: Date, endedAt: Date) throws {
    guard endedAt >= startedAt, queuedAt.map({ $0 <= startedAt }) ?? true else {
      throw AgentExecutionEvidenceError.invalidTaskTiming
    }
    self.queuedAt = queuedAt
    self.startedAt = startedAt
    self.endedAt = endedAt
  }

  public var duration: TimeInterval {
    endedAt.timeIntervalSince(startedAt)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      queuedAt: container.decodeIfPresent(Date.self, forKey: .queuedAt),
      startedAt: container.decode(Date.self, forKey: .startedAt),
      endedAt: container.decode(Date.self, forKey: .endedAt)
    )
  }
}

/// Deterministic terminal settlement for a child or background task.
public enum AgentTaskSettlementStatus: String, Codable, Equatable, Sendable {
  case succeeded
  /// Policy or approval rejected the task before its requested work could complete.
  case denied
  case failed
  case cancelled
  /// The task reached its caller-owned terminal deadline.
  case timedOut
  /// The process crashed after work may have escaped, and external effects cannot be proven.
  case ambiguousAfterCrash
}

public struct AgentTaskSettlementReason: Codable, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  public func redacted(using policy: FoundationModelsAgentRedactionPolicy) -> Self {
    Self(code: policy.redact(code), message: policy.redact(message))
  }
}

/// Structured terminal result returned by a future child-agent or background-task implementation.
public struct AgentTaskResult: Codable, Equatable, Sendable {
  public let lineage: AgentRunLineage
  public let status: AgentTaskSettlementStatus
  public let outputReferences: [AgentEvidenceReference]
  public let evidenceReferences: [AgentEvidenceReference]
  public let usage: FoundationModelsAgentUsage?
  public let receipt: AgentReceiptReference?
  public let failureReason: AgentTaskSettlementReason?
  public let cancellationReason: AgentTaskSettlementReason?
  public let timing: AgentTaskTiming

  public init(
    lineage: AgentRunLineage,
    status: AgentTaskSettlementStatus,
    outputReferences: [AgentEvidenceReference] = [],
    evidenceReferences: [AgentEvidenceReference] = [],
    usage: FoundationModelsAgentUsage? = nil,
    receipt: AgentReceiptReference? = nil,
    failureReason: AgentTaskSettlementReason? = nil,
    cancellationReason: AgentTaskSettlementReason? = nil,
    timing: AgentTaskTiming
  ) throws {
    guard let taskID = lineage.taskID else {
      throw AgentExecutionEvidenceError.invalidDescendantLineage
    }
    switch status {
    case .succeeded:
      guard failureReason == nil, cancellationReason == nil else {
        throw AgentExecutionEvidenceError.invalidTaskSettlement(status)
      }
    case .denied, .failed, .timedOut, .ambiguousAfterCrash:
      guard failureReason != nil, cancellationReason == nil else {
        throw AgentExecutionEvidenceError.invalidTaskSettlement(status)
      }
    case .cancelled:
      guard failureReason == nil, cancellationReason != nil else {
        throw AgentExecutionEvidenceError.invalidTaskSettlement(status)
      }
    }
    if let receipt, receipt.runID != lineage.runID {
      throw AgentExecutionEvidenceError.taskReceiptMismatch(taskID)
    }

    self.init(
      validatedLineage: lineage,
      status: status,
      outputReferences: outputReferences,
      evidenceReferences: evidenceReferences,
      usage: usage,
      receipt: receipt,
      failureReason: failureReason,
      cancellationReason: cancellationReason,
      timing: timing
    )
  }

  private init(
    validatedLineage lineage: AgentRunLineage,
    status: AgentTaskSettlementStatus,
    outputReferences: [AgentEvidenceReference],
    evidenceReferences: [AgentEvidenceReference],
    usage: FoundationModelsAgentUsage?,
    receipt: AgentReceiptReference?,
    failureReason: AgentTaskSettlementReason?,
    cancellationReason: AgentTaskSettlementReason?,
    timing: AgentTaskTiming
  ) {
    self.lineage = lineage
    self.status = status
    self.outputReferences = outputReferences
    self.evidenceReferences = evidenceReferences
    self.usage = usage
    self.receipt = receipt
    self.failureReason = failureReason
    self.cancellationReason = cancellationReason
    self.timing = timing
  }

  public func redacted(using policy: FoundationModelsAgentRedactionPolicy) -> Self {
    Self(
      validatedLineage: lineage,
      status: status,
      outputReferences: outputReferences.map { $0.redacted(using: policy) },
      evidenceReferences: evidenceReferences.map { $0.redacted(using: policy) },
      usage: usage,
      receipt: receipt,
      failureReason: failureReason?.redacted(using: policy),
      cancellationReason: cancellationReason?.redacted(using: policy),
      timing: timing
    )
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      lineage: container.decode(AgentRunLineage.self, forKey: .lineage),
      status: container.decode(AgentTaskSettlementStatus.self, forKey: .status),
      outputReferences: container.decodeIfPresent(
        [AgentEvidenceReference].self, forKey: .outputReferences) ?? [],
      evidenceReferences: container.decodeIfPresent(
        [AgentEvidenceReference].self, forKey: .evidenceReferences) ?? [],
      usage: container.decodeIfPresent(FoundationModelsAgentUsage.self, forKey: .usage),
      receipt: container.decodeIfPresent(AgentReceiptReference.self, forKey: .receipt),
      failureReason: container.decodeIfPresent(
        AgentTaskSettlementReason.self, forKey: .failureReason),
      cancellationReason: container.decodeIfPresent(
        AgentTaskSettlementReason.self, forKey: .cancellationReason),
      timing: container.decode(AgentTaskTiming.self, forKey: .timing)
    )
  }
}

/// A complete set of receipts and task settlements for one or more rooted execution trees.
public struct AgentReceiptBundle: Codable, Equatable, Sendable {
  public let receipts: [FoundationModelsAgentRunReceipt]
  public let taskResults: [AgentTaskResult]

  public init(
    receipts: [FoundationModelsAgentRunReceipt],
    taskResults: [AgentTaskResult] = []
  ) {
    self.receipts = receipts
    self.taskResults = taskResults
  }

  /// Verifies every hash chain, rejects orphaned or cyclic ancestry, and checks task links.
  ///
  /// A legacy single-run receipt without lineage remains valid. Once a bundle contains more than
  /// one receipt or any task result, every receipt must carry explicit lineage.
  public func verify(maximumDepth: AgentRunDepth? = nil) throws {
    var byID: [AgentRunID: FoundationModelsAgentRunReceipt] = [:]
    for receipt in receipts {
      let runID = AgentRunID(rawValue: receipt.runID)
      guard receipt.verify() else {
        throw AgentExecutionEvidenceError.invalidReceipt(runID)
      }
      guard byID.updateValue(receipt, forKey: runID) == nil else {
        throw AgentExecutionEvidenceError.duplicateRunID(runID)
      }
    }

    if receipts.count == 1, taskResults.isEmpty, receipts[0].lineage == nil {
      return
    }

    let orderedRunIDs = byID.keys.sorted { $0.description < $1.description }
    var lineages: [AgentRunID: AgentRunLineage] = [:]
    for runID in orderedRunIDs {
      let receipt = byID[runID]!
      guard let lineage = receipt.lineage else {
        throw AgentExecutionEvidenceError.missingLineage(runID)
      }
      guard lineage.runID == runID else {
        throw AgentExecutionEvidenceError.runLineageMismatch(runID)
      }
      lineages[runID] = lineage
    }

    for runID in orderedRunIDs {
      let lineage = lineages[runID]!
      if let maximumDepth, lineage.depth > maximumDepth {
        throw AgentExecutionEvidenceError.maximumDepthExceeded(
          runID: runID, maximum: maximumDepth)
      }
      guard let root = lineages[lineage.rootRunID] else {
        throw AgentExecutionEvidenceError.missingRoot(
          runID: runID, rootRunID: lineage.rootRunID)
      }
      guard root.relationship == .root else {
        throw AgentExecutionEvidenceError.inconsistentRoot(runID: runID)
      }
      guard let parentRunID = lineage.parentRunID else {
        continue
      }
      guard let parent = lineages[parentRunID] else {
        throw AgentExecutionEvidenceError.orphanedRun(
          runID: runID, missingParentRunID: parentRunID)
      }

      var visited: Set<AgentRunID> = [runID]
      var cursor: AgentRunLineage? = parent
      while let current = cursor {
        guard visited.insert(current.runID).inserted else {
          throw AgentExecutionEvidenceError.cycleDetected(current.runID)
        }
        cursor = current.parentRunID.flatMap { lineages[$0] }
      }

      guard parent.rootRunID == lineage.rootRunID else {
        throw AgentExecutionEvidenceError.inconsistentRoot(runID: runID)
      }
      guard parent.depth.rawValue < Int.max,
        lineage.depth.rawValue == parent.depth.rawValue + 1
      else {
        throw AgentExecutionEvidenceError.inconsistentDepth(runID: runID)
      }
    }

    var taskIDs: Set<AgentTaskID> = []
    for result in taskResults {
      guard let taskID = result.lineage.taskID else {
        throw AgentExecutionEvidenceError.invalidDescendantLineage
      }
      guard taskIDs.insert(taskID).inserted else {
        throw AgentExecutionEvidenceError.duplicateTaskID(taskID)
      }
      guard let receipt = byID[result.lineage.runID] else {
        throw AgentExecutionEvidenceError.missingTaskReceipt(taskID)
      }
      guard receipt.lineage == result.lineage,
        result.receipt.map({
          $0.runID == result.lineage.runID && $0.rootHash == receipt.rootHash
        }) ?? true
      else {
        throw AgentExecutionEvidenceError.taskReceiptMismatch(taskID)
      }

      var evidenceReferenceIDs: Set<AgentEvidenceReferenceID> = []
      for reference in result.outputReferences + result.evidenceReferences {
        guard evidenceReferenceIDs.insert(reference.id).inserted else {
          throw AgentExecutionEvidenceError.duplicateEvidenceReferenceID(reference.id)
        }
        guard let referencedRunID = reference.runID else {
          continue
        }
        guard let referencedReceipt = byID[referencedRunID] else {
          throw AgentExecutionEvidenceError.missingEvidenceRun(
            referenceID: reference.id,
            runID: referencedRunID
          )
        }
        guard let eventID = reference.eventID else {
          continue
        }
        guard
          let event = referencedReceipt.receipts.lazy.map(\.event).first(where: {
            $0.id == eventID
          })
        else {
          if byID.values.lazy
            .flatMap(\.receipts)
            .contains(where: { $0.event.id == eventID })
          {
            throw AgentExecutionEvidenceError.evidenceEventRunMismatch(
              referenceID: reference.id
            )
          }
          throw AgentExecutionEvidenceError.missingEvidenceEvent(
            referenceID: reference.id,
            eventID: eventID
          )
        }
        guard event.runID == referencedRunID.rawValue else {
          throw AgentExecutionEvidenceError.evidenceEventRunMismatch(
            referenceID: reference.id
          )
        }
      }
    }
  }
}

/// Deterministic JSON and atomic-file transport for a complete receipt bundle.
public struct AgentReceiptBundleExporter: Sendable {
  public init() {}

  public func data(
    for bundle: AgentReceiptBundle,
    prettyPrinted: Bool = true
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return try encoder.encode(bundle)
  }

  public func write(
    _ bundle: AgentReceiptBundle,
    to url: URL,
    prettyPrinted: Bool = true
  ) throws {
    try data(for: bundle, prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
  }

  public func decode(_ data: Data) throws -> AgentReceiptBundle {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(AgentReceiptBundle.self, from: data)
  }

  public func decode(contentsOf url: URL) throws -> AgentReceiptBundle {
    try decode(Data(contentsOf: url))
  }
}
