import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CryptoKit
import Foundation
import Observation
import SwiftData

public enum CoreAgentRunProjectionStatus: String, Codable, Equatable, Sendable {
  case running
  case completed
  case failed
}

public struct CoreAgentRunProjection: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID { runID }

  public let runID: UUID
  public let projectID: String
  public let threadID: String?
  public let startedAt: Date
  public let endedAt: Date
  public let duration: TimeInterval
  public let status: CoreAgentRunProjectionStatus
  public let lastEventKind: CoreAgentEventKind?
  public let eventCounts: [CoreAgentEventKind: Int]
  public let ingestedAt: Date

  public init(trace: CoreAgentEngineTrace) {
    self.runID = trace.run.id
    self.projectID = trace.projectID
    self.threadID = trace.threadID
    self.startedAt = trace.run.startedAt
    self.endedAt = trace.run.endedAt
    self.duration = trace.run.duration
    self.status = Self.status(for: trace.run)
    self.lastEventKind = trace.run.events.last?.kind
    self.eventCounts = Dictionary(
      grouping: trace.run.events,
      by: \.kind
    ).mapValues(\.count)
    self.ingestedAt = trace.ingestedAt
  }

  private static func status(for run: CoreAgentRun) -> CoreAgentRunProjectionStatus {
    if run.events.contains(where: { $0.kind == .runFailed }) {
      return .failed
    }
    if run.events.contains(where: { $0.kind == .runCompleted }) {
      return .completed
    }
    return .running
  }
}

@MainActor
@Observable
public final class CoreAgentRunProjectionStore {
  public private(set) var projections: [CoreAgentRunProjection]

  public init(projections: [CoreAgentRunProjection] = []) {
    self.projections = projections
  }

  public func apply(traces: [CoreAgentEngineTrace]) {
    var projectionsByRunID: [UUID: CoreAgentRunProjection] = Dictionary(
      uniqueKeysWithValues: projections.map { ($0.runID, $0) }
    )
    for trace in traces {
      projectionsByRunID[trace.run.id] = CoreAgentRunProjection(trace: trace)
    }
    projections = projectionsByRunID.values
      .sorted { lhs, rhs in
        if lhs.startedAt != rhs.startedAt {
          return lhs.startedAt < rhs.startedAt
        }
        return lhs.runID.uuidString < rhs.runID.uuidString
      }
  }
}
