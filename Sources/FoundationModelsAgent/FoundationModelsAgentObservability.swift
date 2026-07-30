import CryptoKit
import Foundation

public enum FoundationModelsAgentEventKind: String, Codable, Equatable, Sendable {
  case runStarted
  case routeSelected
  case routeCandidateRejected
  case modelAttemptStarted
  case modelAttemptFailed
  case modelResponseCompleted
  case contextBudgetEvaluated
  case contextBudgetTransformed
  case contextBudgetFailed
  case pluginPreparationStarted
  case pluginPreparationCompleted
  case pluginPreparationFailed
  case pluginCompletionStarted
  case pluginCompletionCompleted
  case pluginCompletionFailed
  case pluginEvent
  case profileToolAuditBestEffort
  case profileToolAllowed
  case profileToolDenied
  case profileToolApprovalFailed
  case profileToolBudgetExhausted
  case toolAuthorizationStarted
  case toolAuthorizationSucceeded
  case toolAuthorizationDenied
  case toolAuthorizationCancelled
  case toolAuthorizationFailed
  case toolExecutionStarted
  case toolExecutionCompleted
  case toolExecutionFailed
  case nativeToolCallRecorded
  case nativeToolOutputRecorded
  case transcriptCheckpointed
  case transcriptCheckpointFailed
  case runCompleted
  case runFailed
}

public struct FoundationModelsAgentEvent: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let runID: UUID
  public let timestamp: Date
  public let kind: FoundationModelsAgentEventKind
  public let message: String
  public let attributes: [String: String]
  /// Present for new runs and absent when decoding legacy event exports.
  public let lineage: AgentRunLineage?

  public init(
    id: UUID = UUID(),
    runID: UUID,
    timestamp: Date = Date(),
    kind: FoundationModelsAgentEventKind,
    message: String,
    attributes: [String: String] = [:],
    lineage: AgentRunLineage? = nil
  ) {
    self.id = id
    self.runID = runID
    self.timestamp = timestamp
    self.kind = kind
    self.message = message
    self.attributes = attributes
    self.lineage = lineage
  }
}

public protocol FoundationModelsAgentObserver: Sendable {
  func receive(_ event: FoundationModelsAgentEvent) async
}

public struct ClosureFoundationModelsAgentObserver: FoundationModelsAgentObserver {
  private let handler: @Sendable (FoundationModelsAgentEvent) async -> Void

  public init(_ handler: @escaping @Sendable (FoundationModelsAgentEvent) async -> Void) {
    self.handler = handler
  }

  public func receive(_ event: FoundationModelsAgentEvent) async {
    await handler(event)
  }
}

public enum FoundationModelsAgentObserverOverflowPolicy: Sendable {
  /// Preserve the newest events when an observer cannot keep up.
  case dropOldest
  /// Preserve the events already waiting for delivery.
  case dropNewest
}

public struct FoundationModelsAgentObserverDeliveryConfiguration: Sendable {
  public var maximumPendingEvents: Int
  public var overflowPolicy: FoundationModelsAgentObserverOverflowPolicy
  public var defaultFlushTimeout: Duration

  public init(
    maximumPendingEvents: Int = 256,
    overflowPolicy: FoundationModelsAgentObserverOverflowPolicy = .dropOldest,
    defaultFlushTimeout: Duration = .seconds(5)
  ) {
    self.maximumPendingEvents = maximumPendingEvents
    self.overflowPolicy = overflowPolicy
    self.defaultFlushTimeout = defaultFlushTimeout
  }

  public static let `default` = FoundationModelsAgentObserverDeliveryConfiguration()
}

public enum FoundationModelsAgentObserverFlushStatus: Sendable, Equatable {
  /// Every queued event covered by the flush barrier is now settled.
  case drained
  /// At least one observer did not settle its covered events before the deadline.
  case timedOut
  /// The task waiting for observer delivery was cancelled.
  case cancelled
  /// An observer tried to flush its own delivery queue.
  case reentrant
}

public struct FoundationModelsAgentObserverFlushResult: Sendable, Equatable {
  public let status: FoundationModelsAgentObserverFlushStatus
  /// Total events dropped by all observer queues since this session was created.
  public let cumulativeDroppedEventCount: Int

  public init(
    status: FoundationModelsAgentObserverFlushStatus,
    cumulativeDroppedEventCount: Int
  ) {
    self.status = status
    self.cumulativeDroppedEventCount = cumulativeDroppedEventCount
  }

  /// `true` only when the barrier drained and no observer event has ever been dropped.
  public var deliveredAllEvents: Bool {
    status == .drained && cumulativeDroppedEventCount == 0
  }
}

public struct FoundationModelsAgentRedactionPolicy: Sendable {
  private let redactor: @Sendable (String) -> String

  public init(_ redactor: @escaping @Sendable (String) -> String) {
    self.redactor = redactor
  }

  public func redact(_ value: String) -> String {
    redactor(value)
  }

  public static let none = FoundationModelsAgentRedactionPolicy { $0 }

  public static let standard = FoundationModelsAgentRedactionPolicy { value in
    var result = value
    let patterns: [(String, String)] = [
      (#"(?i)bearer\s+[a-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
      (#"(?i)\bsk-[a-z0-9_-]{8,}\b"#, "[REDACTED_API_KEY]"),
      (
        #"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,;]+"#,
        "$1=[REDACTED]"
      ),
    ]
    for (pattern, replacement) in patterns {
      result = result.replacingOccurrences(
        of: pattern,
        with: replacement,
        options: .regularExpression
      )
    }
    return result
  }

  func redact(attributes: [String: String]) -> [String: String] {
    let sensitiveMarkers = ["authorization", "api_key", "apikey", "token", "secret", "password"]
    return attributes.mapValues { redactor($0) }.reduce(into: [:]) { result, pair in
      let key = pair.key.lowercased()
      let usageTokenCountKeys = [
        "input_tokens",
        "cached_input_tokens",
        "output_tokens",
        "reasoning_tokens",
      ]
      let contextTokenCountSuffixes = [
        "_instructions_tokens",
        "_tools_tokens",
        "_prompt_tokens",
        "_schema_tokens",
        "_transcript_tokens",
        "_total_input_tokens",
        "_usable_input_tokens",
      ]
      let isNumericTokenCount =
        (usageTokenCountKeys.contains(key)
          || contextTokenCountSuffixes.contains(where: {
            (key.hasPrefix("before_") || key.hasPrefix("after_"))
              && key.hasSuffix($0)
          }))
        && Int(pair.value) != nil
      if sensitiveMarkers.contains(where: { key.contains($0) }), !isNumericTokenCount {
        result[pair.key] = "[REDACTED]"
      } else {
        result[pair.key] = pair.value
      }
    }
  }
}

public struct FoundationModelsAgentRun: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let startedAt: Date
  public let endedAt: Date
  public let usage: FoundationModelsAgentUsage?
  public let events: [FoundationModelsAgentEvent]
  /// Present for new runs and absent when decoding legacy trace exports.
  public let lineage: AgentRunLineage?
  /// The pre-execution route evidence, present for routed explicit-model runs.
  public let routingDecision: FoundationModelsAgentRouteDecision?

  public init(
    id: UUID,
    startedAt: Date,
    endedAt: Date,
    usage: FoundationModelsAgentUsage?,
    events: [FoundationModelsAgentEvent],
    lineage: AgentRunLineage? = nil,
    routingDecision: FoundationModelsAgentRouteDecision? = nil
  ) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.usage = usage
    self.events = events
    self.lineage = lineage
    self.routingDecision = routingDecision
  }

  public var duration: TimeInterval {
    endedAt.timeIntervalSince(startedAt)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case startedAt
    case endedAt
    case usage
    case events
    case lineage
    case routingDecision
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(UUID.self, forKey: .id)
    self.startedAt = try container.decode(Date.self, forKey: .startedAt)
    self.endedAt = try container.decode(Date.self, forKey: .endedAt)
    self.usage = try container.decodeIfPresent(
      FoundationModelsAgentUsage.self,
      forKey: .usage
    )
    self.events = try container.decode([FoundationModelsAgentEvent].self, forKey: .events)
    self.lineage = try container.decodeIfPresent(AgentRunLineage.self, forKey: .lineage)
    self.routingDecision = try container.decodeIfPresent(
      FoundationModelsAgentRouteDecision.self,
      forKey: .routingDecision
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(endedAt, forKey: .endedAt)
    try container.encodeIfPresent(usage, forKey: .usage)
    try container.encode(events, forKey: .events)
    try container.encodeIfPresent(lineage, forKey: .lineage)
    try container.encodeIfPresent(routingDecision, forKey: .routingDecision)
  }
}

public struct FoundationModelsAgentEventReceipt: Codable, Equatable, Sendable {
  public let index: Int
  public let previousHash: String?
  public let hash: String
  public let event: FoundationModelsAgentEvent

  public init(index: Int, previousHash: String?, hash: String, event: FoundationModelsAgentEvent) {
    self.index = index
    self.previousHash = previousHash
    self.hash = hash
    self.event = event
  }
}

public struct FoundationModelsAgentRunReceipt: Codable, Equatable, Sendable {
  public let runID: UUID
  public let receipts: [FoundationModelsAgentEventReceipt]
  public let rootHash: String?
  /// Present for lineage-aware receipts and absent in legacy receipt fixtures.
  public let lineage: AgentRunLineage?

  public init(
    runID: UUID,
    receipts: [FoundationModelsAgentEventReceipt],
    rootHash: String?,
    lineage: AgentRunLineage? = nil
  ) {
    self.runID = runID
    self.receipts = receipts
    self.rootHash = rootHash
    self.lineage = lineage
  }

  public init(run: FoundationModelsAgentRun) throws {
    if let lineage = run.lineage {
      guard lineage.runID.rawValue == run.id,
        run.events.allSatisfy({ $0.lineage == lineage })
      else {
        throw AgentExecutionEvidenceError.runLineageMismatch(
          AgentRunID(rawValue: run.id))
      }
    } else if !run.events.allSatisfy({ $0.lineage == nil }) {
      throw AgentExecutionEvidenceError.runLineageMismatch(
        AgentRunID(rawValue: run.id))
    }

    var previousHash: String? = try Self.chainSeed(runID: run.id, lineage: run.lineage)
    var values: [FoundationModelsAgentEventReceipt] = []
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]

    for (index, event) in run.events.enumerated() {
      let payload = try Self.payload(
        index: index, previousHash: previousHash, event: event, encoder: encoder)
      let hash = Self.sha256(payload)
      values.append(.init(index: index, previousHash: previousHash, hash: hash, event: event))
      previousHash = hash
    }

    self.runID = run.id
    self.receipts = values
    self.rootHash = previousHash
    self.lineage = run.lineage
  }

  public func verify() -> Bool {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    guard lineage?.runID.rawValue == runID || lineage == nil,
      receipts.allSatisfy({ $0.event.lineage == lineage }),
      let seed = try? Self.chainSeed(runID: runID, lineage: lineage)
    else {
      return false
    }
    var previousHash: String? = seed

    for (index, receipt) in receipts.enumerated() {
      guard receipt.index == index,
        receipt.event.runID == runID,
        receipt.previousHash == previousHash,
        let payload = try? Self.payload(
          index: index,
          previousHash: previousHash,
          event: receipt.event,
          encoder: encoder
        ),
        Self.sha256(payload) == receipt.hash
      else {
        return false
      }
      previousHash = receipt.hash
    }
    return previousHash == rootHash
  }

  private static func payload(
    index: Int,
    previousHash: String?,
    event: FoundationModelsAgentEvent,
    encoder: JSONEncoder
  ) throws -> Data {
    struct Payload: Codable {
      let index: Int
      let previousHash: String?
      let event: FoundationModelsAgentEvent
    }
    return try encoder.encode(Payload(index: index, previousHash: previousHash, event: event))
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func chainSeed(runID: UUID, lineage: AgentRunLineage?) throws -> String {
    guard let lineage else {
      return sha256(
        Data("foundationmodelsagent-receipt-v1\u{0}\(runID.uuidString.lowercased())".utf8))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encodedLineage = try encoder.encode(lineage)
    var seed = Data(
      "foundationmodelsagent-receipt-v2\u{0}\(runID.uuidString.lowercased())\u{0}".utf8)
    seed.append(encodedLineage)
    return sha256(seed)
  }
}

public struct FoundationModelsAgentTraceExporter: Sendable {
  public init() {}

  public func data(for run: FoundationModelsAgentRun, prettyPrinted: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return try encoder.encode(run)
  }

  public func write(_ run: FoundationModelsAgentRun, to url: URL, prettyPrinted: Bool = true) throws
  {
    try data(for: run, prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
  }
}

public struct FoundationModelsAgentReceiptExporter: Sendable {
  public init() {}

  public func data(for run: FoundationModelsAgentRun, prettyPrinted: Bool = true) throws -> Data {
    let receipt = try FoundationModelsAgentRunReceipt(run: run)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return try encoder.encode(receipt)
  }

  public func write(_ run: FoundationModelsAgentRun, to url: URL, prettyPrinted: Bool = true) throws
  {
    try data(for: run, prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
  }

  public func decode(_ data: Data) throws -> FoundationModelsAgentRunReceipt {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(FoundationModelsAgentRunReceipt.self, from: data)
  }

  public func decode(contentsOf url: URL) throws -> FoundationModelsAgentRunReceipt {
    try decode(Data(contentsOf: url))
  }
}

private enum FoundationModelsAgentObserverDeliveryContext {
  @TaskLocal static var isDelivering = false
}

private struct FoundationModelsAgentObserverBarrier: Sendable {
  let sequence: Int
}

private actor FoundationModelsAgentObserverDelivery {
  private struct PendingEvent {
    let sequence: Int
    let event: FoundationModelsAgentEvent
  }

  private let observer: any FoundationModelsAgentObserver
  private let configuration: FoundationModelsAgentObserverDeliveryConfiguration
  private var pending: [PendingEvent] = []
  private var isDelivering = false
  private var nextSequence = 0
  private var unsettledSequences: Set<Int> = []
  private var cumulativeDroppedEventCount = 0

  init(
    observer: any FoundationModelsAgentObserver,
    configuration: FoundationModelsAgentObserverDeliveryConfiguration
  ) {
    self.observer = observer
    self.configuration = configuration
  }

  func enqueue(_ event: FoundationModelsAgentEvent) {
    let item = PendingEvent(sequence: nextSequence, event: event)
    nextSequence += 1

    if pending.count >= configuration.maximumPendingEvents {
      switch configuration.overflowPolicy {
      case .dropOldest:
        let dropped = pending.removeFirst()
        unsettledSequences.remove(dropped.sequence)
        cumulativeDroppedEventCount += 1
      case .dropNewest:
        cumulativeDroppedEventCount += 1
        return
      }
    }

    pending.append(item)
    unsettledSequences.insert(item.sequence)
    guard !isDelivering else { return }
    isDelivering = true
    Task { await drain() }
  }

  func barrier() -> FoundationModelsAgentObserverBarrier {
    FoundationModelsAgentObserverBarrier(sequence: nextSequence - 1)
  }

  func hasSettled(through sequence: Int) -> Bool {
    !unsettledSequences.contains { $0 <= sequence }
  }

  func droppedEventCount() -> Int {
    cumulativeDroppedEventCount
  }

  private func drain() async {
    while !pending.isEmpty {
      let item = pending.removeFirst()
      await FoundationModelsAgentObserverDeliveryContext.$isDelivering.withValue(true) {
        await observer.receive(item.event)
      }
      unsettledSequences.remove(item.sequence)
    }
    isDelivering = false
  }
}

actor FoundationModelsAgentEventRecorder {
  private let deliveries: [FoundationModelsAgentObserverDelivery]
  private let deliveryConfiguration: FoundationModelsAgentObserverDeliveryConfiguration
  private let redactionPolicy: FoundationModelsAgentRedactionPolicy
  private var eventsByRun: [UUID: [FoundationModelsAgentEvent]] = [:]
  private var lineageByRun: [UUID: AgentRunLineage] = [:]

  init(
    observers: [any FoundationModelsAgentObserver],
    redactionPolicy: FoundationModelsAgentRedactionPolicy,
    deliveryConfiguration: FoundationModelsAgentObserverDeliveryConfiguration
  ) {
    self.deliveries = observers.map {
      FoundationModelsAgentObserverDelivery(observer: $0, configuration: deliveryConfiguration)
    }
    self.deliveryConfiguration = deliveryConfiguration
    self.redactionPolicy = redactionPolicy
  }

  func begin(lineage: AgentRunLineage, message: String) async {
    let runID = lineage.runID.rawValue
    eventsByRun[runID] = []
    lineageByRun[runID] = lineage
    await record(runID: runID, kind: .runStarted, message: message)
  }

  func record(
    runID: UUID,
    kind: FoundationModelsAgentEventKind,
    message: String,
    attributes: [String: String] = [:]
  ) async {
    let event = FoundationModelsAgentEvent(
      runID: runID,
      kind: kind,
      message: redactionPolicy.redact(message),
      attributes: redactionPolicy.redact(attributes: attributes),
      lineage: lineageByRun[runID]
    )
    eventsByRun[runID, default: []].append(event)
    for delivery in deliveries {
      await delivery.enqueue(event)
    }
  }

  func events(for runID: UUID) -> [FoundationModelsAgentEvent] {
    eventsByRun[runID] ?? []
  }

  func discard(runID: UUID) {
    eventsByRun.removeValue(forKey: runID)
    lineageByRun.removeValue(forKey: runID)
  }

  func flushObservers(timeout: Duration? = nil) async -> FoundationModelsAgentObserverFlushResult {
    guard !FoundationModelsAgentObserverDeliveryContext.isDelivering else {
      return FoundationModelsAgentObserverFlushResult(
        status: .reentrant,
        cumulativeDroppedEventCount: await cumulativeDroppedEventCount()
      )
    }

    var barriers: [(FoundationModelsAgentObserverDelivery, FoundationModelsAgentObserverBarrier)] =
      []
    for delivery in deliveries {
      barriers.append((delivery, await delivery.barrier()))
    }
    guard !barriers.isEmpty else {
      return FoundationModelsAgentObserverFlushResult(
        status: .drained,
        cumulativeDroppedEventCount: 0
      )
    }

    let duration = timeout ?? deliveryConfiguration.defaultFlushTimeout
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    while true {
      var complete = true
      for (delivery, barrier) in barriers
      where !(await delivery.hasSettled(through: barrier.sequence)) {
        complete = false
        break
      }
      if complete {
        return FoundationModelsAgentObserverFlushResult(
          status: .drained,
          cumulativeDroppedEventCount: await cumulativeDroppedEventCount()
        )
      }
      if Task.isCancelled {
        return FoundationModelsAgentObserverFlushResult(
          status: .cancelled,
          cumulativeDroppedEventCount: await cumulativeDroppedEventCount()
        )
      }
      if duration <= .zero || clock.now >= deadline {
        return FoundationModelsAgentObserverFlushResult(
          status: .timedOut,
          cumulativeDroppedEventCount: await cumulativeDroppedEventCount()
        )
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  private func cumulativeDroppedEventCount() async -> Int {
    var count = 0
    for delivery in deliveries {
      count += await delivery.droppedEventCount()
    }
    return count
  }
}
