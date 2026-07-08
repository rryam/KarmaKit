import CoreAgent
import CryptoKit
import Foundation
import FoundationModels

public struct CoreAgentDeepSubagentBudget: Codable, Equatable, Sendable {
  public let maximumDepth: Int?
  public let maximumDelegations: Int?
  public let maximumTotalTokens: Int?

  public init(
    maximumDepth: Int? = nil,
    maximumDelegations: Int? = nil,
    maximumTotalTokens: Int? = nil
  ) {
    self.maximumDepth = maximumDepth.map { max(0, $0) }
    self.maximumDelegations = maximumDelegations.map { max(0, $0) }
    self.maximumTotalTokens = maximumTotalTokens.map { max(0, $0) }
  }

  public static let unlimited = CoreAgentDeepSubagentBudget()
  public static let modelFacingDefault = CoreAgentDeepSubagentBudget(
    maximumDepth: 4,
    maximumDelegations: 16
  )
}

public struct CoreAgentDeepSubagentBudgetState: Codable, Equatable, Sendable {
  public let depth: Int
  public let maximumDepth: Int?
  public let delegationsUsed: Int
  public let maximumDelegations: Int?
  public let totalTokensUsed: Int
  public let maximumTotalTokens: Int?

  public init(
    depth: Int,
    maximumDepth: Int?,
    delegationsUsed: Int,
    maximumDelegations: Int?,
    totalTokensUsed: Int = 0,
    maximumTotalTokens: Int? = nil
  ) {
    self.depth = depth
    self.maximumDepth = maximumDepth
    self.delegationsUsed = delegationsUsed
    self.maximumDelegations = maximumDelegations
    self.totalTokensUsed = totalTokensUsed
    self.maximumTotalTokens = maximumTotalTokens
  }
}

public enum CoreAgentDeepSubagentBudgetError:
  Error, Equatable, LocalizedError, Sendable
{
  case maxDepthExceeded(maximumDepth: Int, attemptedDepth: Int)
  case delegationLimitExceeded(maximumDelegations: Int)
  case tokenBudgetExceeded(maximumTotalTokens: Int, totalTokensUsed: Int)

  public var errorDescription: String? {
    switch self {
    case .maxDepthExceeded(let maximumDepth, let attemptedDepth):
      "Subagent recursion depth \(attemptedDepth) exceeds the configured maximum depth \(maximumDepth)."
    case .delegationLimitExceeded(let maximumDelegations):
      "Subagent delegation budget exhausted after \(maximumDelegations) delegation(s)."
    case .tokenBudgetExceeded(let maximumTotalTokens, let totalTokensUsed):
      "Subagent token budget exhausted after \(totalTokensUsed) token(s); configured maximum is \(maximumTotalTokens)."
    }
  }
}

actor CoreAgentDeepSubagentBudgetTracker {
  private let budget: CoreAgentDeepSubagentBudget
  private var delegationsUsed = 0
  private var totalTokensUsed = 0

  init(budget: CoreAgentDeepSubagentBudget) {
    self.budget = budget
  }

  func reserve(attemptedDepth: Int) throws -> CoreAgentDeepSubagentBudgetState {
    if let maximumDepth = budget.maximumDepth, attemptedDepth > maximumDepth {
      throw CoreAgentDeepSubagentBudgetError.maxDepthExceeded(
        maximumDepth: maximumDepth,
        attemptedDepth: attemptedDepth
      )
    }
    if let maximumDelegations = budget.maximumDelegations,
      delegationsUsed >= maximumDelegations
    {
      throw CoreAgentDeepSubagentBudgetError.delegationLimitExceeded(
        maximumDelegations: maximumDelegations
      )
    }
    if let maximumTotalTokens = budget.maximumTotalTokens,
      totalTokensUsed >= maximumTotalTokens
    {
      throw CoreAgentDeepSubagentBudgetError.tokenBudgetExceeded(
        maximumTotalTokens: maximumTotalTokens,
        totalTokensUsed: totalTokensUsed
      )
    }
    delegationsUsed += 1
    return currentState(depth: attemptedDepth)
  }

  func recordUsage(
    _ usage: CoreAgentUsage?,
    depth: Int
  ) throws -> CoreAgentDeepSubagentBudgetState {
    if let usage {
      totalTokensUsed += usage.totalTokenCount
    }
    if let maximumTotalTokens = budget.maximumTotalTokens,
      totalTokensUsed > maximumTotalTokens
    {
      throw CoreAgentDeepSubagentBudgetError.tokenBudgetExceeded(
        maximumTotalTokens: maximumTotalTokens,
        totalTokensUsed: totalTokensUsed
      )
    }
    return currentState(depth: depth)
  }

  func currentState(depth: Int) -> CoreAgentDeepSubagentBudgetState {
    CoreAgentDeepSubagentBudgetState(
      depth: depth,
      maximumDepth: budget.maximumDepth,
      delegationsUsed: delegationsUsed,
      maximumDelegations: budget.maximumDelegations,
      totalTokensUsed: totalTokensUsed,
      maximumTotalTokens: budget.maximumTotalTokens
    )
  }
}

actor CoreAgentDeepSubagentBudgetRegistry {
  private var trackers: [UUID: CoreAgentDeepSubagentBudgetTracker] = [:]

  func tracker(
    for rootID: UUID,
    budget: CoreAgentDeepSubagentBudget
  ) -> CoreAgentDeepSubagentBudgetTracker {
    if let tracker = trackers[rootID] {
      return tracker
    }
    let tracker = CoreAgentDeepSubagentBudgetTracker(budget: budget)
    trackers[rootID] = tracker
    return tracker
  }

  func removeTracker(for rootID: UUID) {
    trackers[rootID] = nil
  }

  func removeAll() {
    trackers.removeAll()
  }

  func count() -> Int {
    trackers.count
  }
}

enum CoreAgentDeepSubagentBudgetContext {
  struct Active: Sendable {
    let state: CoreAgentDeepSubagentBudgetState
    let tracker: CoreAgentDeepSubagentBudgetTracker
  }

  @TaskLocal static var current: Active?
}
