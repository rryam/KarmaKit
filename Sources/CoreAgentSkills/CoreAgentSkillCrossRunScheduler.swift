import Foundation

public enum CoreAgentSkillOptimizationCrossRunSchedulerTrigger:
  String, Codable, Equatable, Sendable
{
  case hostInvoked
}

public struct CoreAgentSkillOptimizationCrossRunSchedulerPolicy:
  Codable, Equatable, Sendable
{
  public let maximumRequestsPerHostInvocation: Int
  public let prioritizeRejectedSkillTargets: Bool
  public let trigger: CoreAgentSkillOptimizationCrossRunSchedulerTrigger

  public init(
    maximumRequestsPerHostInvocation: Int = Int.max,
    prioritizeRejectedSkillTargets: Bool = true,
    trigger: CoreAgentSkillOptimizationCrossRunSchedulerTrigger = .hostInvoked
  ) {
    self.maximumRequestsPerHostInvocation = maximumRequestsPerHostInvocation
    self.prioritizeRejectedSkillTargets = prioritizeRejectedSkillTargets
    self.trigger = trigger
  }

  func validate() throws {
    guard maximumRequestsPerHostInvocation > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maximumRequestsPerHostInvocation must be positive"
      )
    }
    guard trigger == .hostInvoked else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "cross-run scheduler trigger must be hostInvoked"
      )
    }
  }
}

public struct CoreAgentSkillOptimizationCrossRunSchedulerDecision: Sendable {
  public let requests: [CoreAgentSkillOptimizationRunRequest]
  public let carryOverRunIDs: [String]
  public let completedRunIDs: [String]
  public let prioritizedSkillIDs: [CoreAgentSkillID]

  public init(
    requests: [CoreAgentSkillOptimizationRunRequest],
    carryOverRunIDs: [String],
    completedRunIDs: [String],
    prioritizedSkillIDs: [CoreAgentSkillID]
  ) {
    self.requests = requests
    self.carryOverRunIDs = carryOverRunIDs
    self.completedRunIDs = completedRunIDs
    self.prioritizedSkillIDs = prioritizedSkillIDs
  }
}

public struct CoreAgentSkillOptimizationCrossRunSchedulerPlan: Sendable {
  public let policy: CoreAgentSkillOptimizationCrossRunSchedulerPolicy
  public let backlog: [CoreAgentSkillOptimizationRunRequest]

  public init(
    policy: CoreAgentSkillOptimizationCrossRunSchedulerPolicy =
      CoreAgentSkillOptimizationCrossRunSchedulerPolicy(),
    backlog: [CoreAgentSkillOptimizationRunRequest]
  ) {
    self.policy = policy
    self.backlog = backlog
  }

  public var trigger: CoreAgentSkillOptimizationCrossRunSchedulerTrigger {
    policy.trigger
  }

  public func nextRequests<Reports: Sequence>(
    after reports: Reports
  ) throws -> CoreAgentSkillOptimizationCrossRunSchedulerDecision
  where Reports.Element == CoreAgentSkillOptimizationRunReport {
    try policy.validate()
    try validateBacklog()
    let canonicalReports = try Self.canonicalReports(Array(reports))
    let completedRunIDs = Self.completedRunIDs(from: canonicalReports)
    let completed = Set(completedRunIDs)
    let prioritizedSkillIDs =
      policy.prioritizeRejectedSkillTargets
      ? Self.prioritizedRejectedSkillIDs(from: canonicalReports)
      : []
    let rankBySkillID = Dictionary(
      uniqueKeysWithValues: prioritizedSkillIDs.enumerated().map { ($1, $0) }
    )
    let candidates = backlog.enumerated().compactMap { index, request -> Candidate? in
      guard !completed.contains(request.runID) else { return nil }
      return Candidate(
        request: request,
        originalIndex: index,
        rejectedPriority: Self.rejectedPriority(
          for: request,
          rankBySkillID: rankBySkillID
        )
      )
    }
    let ordered = candidates.sorted(by: Self.candidateSort).map(\.request)
    return CoreAgentSkillOptimizationCrossRunSchedulerDecision(
      requests: Array(ordered.prefix(policy.maximumRequestsPerHostInvocation)),
      carryOverRunIDs: ordered.map(\.runID),
      completedRunIDs: completedRunIDs,
      prioritizedSkillIDs: prioritizedSkillIDs
    )
  }

  private func validateBacklog() throws {
    var seenRunIDs: Set<String> = []
    for request in backlog {
      guard !request.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "cross-run scheduler request run IDs must be non-empty"
        )
      }
      guard seenRunIDs.insert(request.runID).inserted else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "cross-run scheduler request run IDs must be unique"
        )
      }
    }
  }

  private static func canonicalReports(
    _ reports: [CoreAgentSkillOptimizationRunReport]
  ) throws -> [CoreAgentSkillOptimizationRunReport] {
    var seenRunIDs: Set<String> = []
    for report in reports {
      guard !report.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "cross-run scheduler report run IDs must be non-empty"
        )
      }
      guard seenRunIDs.insert(report.runID).inserted else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "cross-run scheduler report run IDs must be unique"
        )
      }
    }
    return reports.sorted { lhs, rhs in
      lhs.runID < rhs.runID
    }
  }

  private static func completedRunIDs(
    from reports: [CoreAgentSkillOptimizationRunReport]
  ) -> [String] {
    reports.map(\.runID)
  }

  private static func prioritizedRejectedSkillIDs(
    from reports: [CoreAgentSkillOptimizationRunReport]
  ) -> [CoreAgentSkillID] {
    var counts: [CoreAgentSkillID: Int] = [:]
    for report in reports {
      for entry in report.sleepReport?.entries ?? [] {
        if case .rejected = entry.decision {
          counts[entry.skillID, default: 0] += 1
        }
      }
    }
    return counts.keys.sorted { lhs, rhs in
      let lhsCount = counts[lhs, default: 0]
      let rhsCount = counts[rhs, default: 0]
      if lhsCount != rhsCount {
        return lhsCount > rhsCount
      }
      return lhs.rawValue < rhs.rawValue
    }
  }

  private static func rejectedPriority(
    for request: CoreAgentSkillOptimizationRunRequest,
    rankBySkillID: [CoreAgentSkillID: Int]
  ) -> RejectedPriority {
    var bestRank = Int.max
    var matchedCount = 0
    for target in request.targets {
      if let rank = rankBySkillID[target.skillID] {
        bestRank = min(bestRank, rank)
        matchedCount += 1
      }
    }
    return RejectedPriority(matchedCount: matchedCount, bestRank: bestRank)
  }

  private static func candidateSort(lhs: Candidate, rhs: Candidate) -> Bool {
    if lhs.rejectedPriority.matchedCount != rhs.rejectedPriority.matchedCount {
      return lhs.rejectedPriority.matchedCount > rhs.rejectedPriority.matchedCount
    }
    if lhs.rejectedPriority.bestRank != rhs.rejectedPriority.bestRank {
      return lhs.rejectedPriority.bestRank < rhs.rejectedPriority.bestRank
    }
    if lhs.originalIndex != rhs.originalIndex {
      return lhs.originalIndex < rhs.originalIndex
    }
    return lhs.request.runID < rhs.request.runID
  }

  private struct Candidate {
    let request: CoreAgentSkillOptimizationRunRequest
    let originalIndex: Int
    let rejectedPriority: RejectedPriority
  }

  private struct RejectedPriority {
    let matchedCount: Int
    let bestRank: Int
  }
}
