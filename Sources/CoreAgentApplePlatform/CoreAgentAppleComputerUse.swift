import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CryptoKit
import Foundation
import Observation
import SwiftData

public enum CoreAgentAppleComputerUseMode: String, Codable, Equatable, Sendable {
  case dryRun
  case execute
}

public struct CoreAgentAppleComputerUseRequest: Codable, Equatable, Sendable {
  public let id: String
  public let actionID: String
  public let mode: CoreAgentAppleComputerUseMode
  public let approvedPlan: CoreAgentAppleComputerUsePlan?
  public let approvedPlanDigest: String?

  public init(
    id: String,
    actionID: String,
    mode: CoreAgentAppleComputerUseMode,
    approvedPlan: CoreAgentAppleComputerUsePlan? = nil,
    approvedPlanDigest: String? = nil
  ) {
    self.id = id
    self.actionID = actionID
    self.mode = mode
    self.approvedPlan = approvedPlan
    self.approvedPlanDigest = approvedPlanDigest ?? approvedPlan?.digest
  }
}

public enum CoreAgentAppleComputerUseEvidenceKind: String, Codable, Hashable, Sendable {
  case screenshotDigest
  case accessibilityTreeDigest
  case userVisibleStateDigest
}

public struct CoreAgentAppleComputerUsePlanStep: Codable, Equatable, Sendable {
  public let id: String
  public let summary: String

  public init(id: String, summary: String) {
    self.id = id
    self.summary = summary
  }
}

public struct CoreAgentAppleComputerUsePlan: Codable, Equatable, Sendable {
  public let steps: [CoreAgentAppleComputerUsePlanStep]
  public let requiredEvidence: [CoreAgentAppleComputerUseEvidenceKind]

  public var digest: String {
    Self.digest(self)
  }

  public init(
    steps: [CoreAgentAppleComputerUsePlanStep],
    requiredEvidence: [CoreAgentAppleComputerUseEvidenceKind]
  ) {
    self.steps = steps
    self.requiredEvidence = requiredEvidence
  }

  private static func digest(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(value)
    return "sha256:" + sha256Hex(data)
  }
}

public struct CoreAgentAppleComputerUseEvidence: Codable, Equatable, Sendable {
  public let kind: CoreAgentAppleComputerUseEvidenceKind
  public let digest: String
  public let capturedAt: Date

  public init(
    kind: CoreAgentAppleComputerUseEvidenceKind,
    digest: String,
    capturedAt: Date
  ) {
    self.kind = kind
    self.digest = digest
    self.capturedAt = capturedAt
  }
}

public struct CoreAgentAppleComputerUseBackend: Sendable {
  private let planHandler:
    @Sendable (CoreAgentAppleComputerUseRequest) async throws -> CoreAgentAppleComputerUsePlan
  private let executeHandler:
    @Sendable (
      CoreAgentAppleComputerUseRequest,
      CoreAgentAppleComputerUsePlan
    ) async throws -> [CoreAgentAppleComputerUseEvidence]

  public init(
    plan:
      @escaping @Sendable (
        CoreAgentAppleComputerUseRequest
      ) async throws -> CoreAgentAppleComputerUsePlan,
    execute:
      @escaping @Sendable (
        CoreAgentAppleComputerUseRequest,
        CoreAgentAppleComputerUsePlan
      ) async throws -> [CoreAgentAppleComputerUseEvidence]
  ) {
    self.planHandler = plan
    self.executeHandler = execute
  }

  public func plan(
    _ request: CoreAgentAppleComputerUseRequest
  ) async throws -> CoreAgentAppleComputerUsePlan {
    try await planHandler(request)
  }

  public func execute(
    _ request: CoreAgentAppleComputerUseRequest,
    plan: CoreAgentAppleComputerUsePlan
  ) async throws -> [CoreAgentAppleComputerUseEvidence] {
    try await executeHandler(request, plan)
  }
}

public enum CoreAgentAppleComputerUseFailure: Equatable, Sendable {
  case cancelled
  case backendFailed
  case missingApprovedPlan
  case unapprovedPlanDigest
  case approvedPlanDigestMismatch
  case invalidRequest(String)
  case invalidPlan(String)
  case invalidEvidenceDigest(kind: CoreAgentAppleComputerUseEvidenceKind)
  case missingEvidence(kind: CoreAgentAppleComputerUseEvidenceKind)
}

public enum CoreAgentAppleComputerUseStatus: Equatable, Sendable {
  case planned
  case executed
  case denied(CoreAgentAppleActionGateDenial)
  case failed(CoreAgentAppleComputerUseFailure)
}

public struct CoreAgentAppleComputerUseAudit: Equatable, Sendable {
  public let requestID: String
  public let actionID: String
  public let mode: CoreAgentAppleComputerUseMode
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let startedAt: Date
  public let endedAt: Date
  public let planDigest: String?
  public let evidenceDigest: String?
  public let status: CoreAgentAppleComputerUseStatus
}

public struct CoreAgentAppleComputerUseResult: Equatable, Sendable {
  public let status: CoreAgentAppleComputerUseStatus
  public let plan: CoreAgentAppleComputerUsePlan?
  public let evidence: [CoreAgentAppleComputerUseEvidence]
  public let audit: CoreAgentAppleComputerUseAudit
}

public struct CoreAgentAppleComputerUseExecutor: Sendable {
  public let actionGate: CoreAgentAppleActionGate
  public let backend: CoreAgentAppleComputerUseBackend
  public let minimumRequiredEvidence: [CoreAgentAppleComputerUseEvidenceKind]
  private let approvedPlans = CoreAgentAppleComputerUseApprovedPlans()
  private let clock: @Sendable () -> Date

  public init(
    actionGate: CoreAgentAppleActionGate,
    backend: CoreAgentAppleComputerUseBackend,
    minimumRequiredEvidence: [CoreAgentAppleComputerUseEvidenceKind] = [.screenshotDigest],
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.actionGate = actionGate
    self.backend = backend
    self.minimumRequiredEvidence = Self.canonicalMinimumEvidence(minimumRequiredEvidence)
    self.clock = clock
  }

  public func run(
    _ request: CoreAgentAppleComputerUseRequest,
    consent: CoreAgentAppleConsent
  ) async -> CoreAgentAppleComputerUseResult {
    let startedAt = clock()
    if let failure = Self.requestFailure(request) {
      return result(
        request: request,
        startedAt: startedAt,
        plan: nil,
        evidence: [],
        status: .failed(failure)
      )
    }
    if request.mode == .execute {
      guard let approvedPlan = request.approvedPlan,
        let approvedPlanDigest = request.approvedPlanDigest
      else {
        return result(
          request: request,
          startedAt: startedAt,
          plan: nil,
          evidence: [],
          status: .failed(.missingApprovedPlan)
        )
      }
      guard approvedPlan.digest == approvedPlanDigest else {
        return result(
          request: request,
          startedAt: startedAt,
          plan: approvedPlan,
          evidence: [],
          status: .failed(.approvedPlanDigestMismatch)
        )
      }
      if let failure = Self.planFailure(
        approvedPlan,
        minimumRequiredEvidence: minimumRequiredEvidence
      ) {
        return result(
          request: request,
          startedAt: startedAt,
          plan: approvedPlan,
          evidence: [],
          status: .failed(failure)
        )
      }
      guard approvedPlans.contains(actionID: request.actionID, digest: approvedPlanDigest) else {
        return result(
          request: request,
          startedAt: startedAt,
          plan: approvedPlan,
          evidence: [],
          status: .failed(.unapprovedPlanDigest)
        )
      }
      return await executeApprovedPlan(
        request,
        plan: approvedPlan,
        approvedPlanDigest: approvedPlanDigest,
        consent: consent,
        startedAt: startedAt
      )
    }

    let gateRequest: CoreAgentAppleExecutionRequest =
      .computerUsePlan(actionID: request.actionID)
    let gateDecision = actionGate.evaluate(
      gateRequest,
      consent: .notRequired
    )
    if case .denied(let denial) = gateDecision {
      return result(
        request: request,
        startedAt: startedAt,
        plan: nil,
        evidence: [],
        status: .denied(denial)
      )
    }
    guard !Task.isCancelled else {
      return result(
        request: request,
        startedAt: startedAt,
        plan: nil,
        evidence: [],
        status: .failed(.cancelled)
      )
    }

    let plan: CoreAgentAppleComputerUsePlan
    do {
      plan = try await backend.plan(request)
    } catch is CancellationError {
      return result(
        request: request,
        startedAt: startedAt,
        plan: nil,
        evidence: [],
        status: .failed(.cancelled)
      )
    } catch {
      if Task.isCancelled {
        return result(
          request: request,
          startedAt: startedAt,
          plan: nil,
          evidence: [],
          status: .failed(.cancelled)
        )
      }
      return result(
        request: request,
        startedAt: startedAt,
        plan: nil,
        evidence: [],
        status: .failed(.backendFailed)
      )
    }
    if let failure = Self.planFailure(
      plan,
      minimumRequiredEvidence: minimumRequiredEvidence
    ) {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: [],
        status: .failed(failure)
      )
    }
    approvedPlans.record(actionID: request.actionID, digest: plan.digest)
    return result(
      request: request,
      startedAt: startedAt,
      plan: plan,
      evidence: [],
      status: .planned
    )
  }

  private func executeApprovedPlan(
    _ request: CoreAgentAppleComputerUseRequest,
    plan: CoreAgentAppleComputerUsePlan,
    approvedPlanDigest: String,
    consent: CoreAgentAppleConsent,
    startedAt: Date
  ) async -> CoreAgentAppleComputerUseResult {
    let gateDecision = actionGate.evaluate(
      .computerUseExecution(
        actionID: request.actionID,
        approvedPlanDigest: approvedPlanDigest
      ),
      consent: consent
    )
    if case .denied(let denial) = gateDecision {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: [],
        status: .denied(denial)
      )
    }
    guard !Task.isCancelled else {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: [],
        status: .failed(.cancelled)
      )
    }

    let evidence: [CoreAgentAppleComputerUseEvidence]
    do {
      evidence = try await backend.execute(request, plan: plan)
    } catch is CancellationError {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: [],
        status: .failed(.cancelled)
      )
    } catch {
      if Task.isCancelled {
        return result(
          request: request,
          startedAt: startedAt,
          plan: plan,
          evidence: [],
          status: .failed(.cancelled)
        )
      }
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: [],
        status: .failed(.backendFailed)
      )
    }
    if Task.isCancelled {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: evidence,
        status: .failed(.cancelled)
      )
    }
    if let failure = Self.evidenceFailure(
      plan: plan,
      evidence: evidence,
      minimumRequiredEvidence: minimumRequiredEvidence
    ) {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: evidence,
        status: .failed(failure)
      )
    }
    return result(
      request: request,
      startedAt: startedAt,
      plan: plan,
      evidence: evidence,
      status: .executed
    )
  }

  private func result(
    request: CoreAgentAppleComputerUseRequest,
    startedAt: Date,
    plan: CoreAgentAppleComputerUsePlan?,
    evidence: [CoreAgentAppleComputerUseEvidence],
    status: CoreAgentAppleComputerUseStatus
  ) -> CoreAgentAppleComputerUseResult {
    CoreAgentAppleComputerUseResult(
      status: status,
      plan: plan,
      evidence: evidence,
      audit: CoreAgentAppleComputerUseAudit(
        requestID: request.id,
        actionID: request.actionID,
        mode: request.mode,
        authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
        policyVersion: actionGate.sandbox.policyVersion,
        workspaceRoot: actionGate.sandbox.workspaceRoot,
        networkPolicy: actionGate.sandbox.networkPolicy,
        startedAt: startedAt,
        endedAt: clock(),
        planDigest: plan?.digest,
        evidenceDigest: evidence.isEmpty ? nil : Self.digest(evidence),
        status: status
      )
    )
  }

  private static func requestFailure(
    _ request: CoreAgentAppleComputerUseRequest
  ) -> CoreAgentAppleComputerUseFailure? {
    guard isBoundedNonEmpty(request.id, maxBytes: 128) else {
      return .invalidRequest("request id")
    }
    guard isBoundedNonEmpty(request.actionID, maxBytes: 256) else {
      return .invalidRequest("action id")
    }
    return nil
  }

  private static func canonicalMinimumEvidence(
    _ configured: [CoreAgentAppleComputerUseEvidenceKind]
  ) -> [CoreAgentAppleComputerUseEvidenceKind] {
    Array(Set(configured).union([.screenshotDigest])).sorted { $0.rawValue < $1.rawValue }
  }

  private static func planFailure(
    _ plan: CoreAgentAppleComputerUsePlan,
    minimumRequiredEvidence: [CoreAgentAppleComputerUseEvidenceKind]
  ) -> CoreAgentAppleComputerUseFailure? {
    guard !plan.steps.isEmpty, plan.steps.count <= 32 else {
      return .invalidPlan("step count")
    }
    var stepIDs: Set<String> = []
    for step in plan.steps {
      guard isBoundedNonEmpty(step.id, maxBytes: 128) else {
        return .invalidPlan("step id")
      }
      guard isBoundedNonEmpty(step.summary, maxBytes: 2048) else {
        return .invalidPlan("step summary")
      }
      guard stepIDs.insert(step.id).inserted else {
        return .invalidPlan("duplicate step id")
      }
    }
    guard plan.requiredEvidence.count <= 8 else {
      return .invalidPlan("evidence requirement count")
    }
    guard Set(plan.requiredEvidence).count == plan.requiredEvidence.count else {
      return .invalidPlan("duplicate evidence requirement")
    }
    for requiredKind in minimumRequiredEvidence
    where !plan.requiredEvidence.contains(requiredKind) {
      return .invalidPlan("missing baseline evidence")
    }
    return nil
  }

  private static func evidenceFailure(
    plan: CoreAgentAppleComputerUsePlan,
    evidence: [CoreAgentAppleComputerUseEvidence],
    minimumRequiredEvidence: [CoreAgentAppleComputerUseEvidenceKind]
  ) -> CoreAgentAppleComputerUseFailure? {
    for item in evidence where !isSHA256Digest(item.digest) {
      return .invalidEvidenceDigest(kind: item.kind)
    }
    let requiredKinds = Array(Set(plan.requiredEvidence).union(minimumRequiredEvidence))
    for requiredKind in requiredKinds
    where !evidence.contains(where: { $0.kind == requiredKind }) {
      return .missingEvidence(kind: requiredKind)
    }
    return nil
  }

  private static func isSHA256Digest(_ digest: String) -> Bool {
    let prefix = "sha256:"
    guard digest.hasPrefix(prefix), digest.count == prefix.count + 64 else {
      return false
    }
    return digest.dropFirst(prefix.count).allSatisfy { character in
      guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
        return false
      }
      return (48...57).contains(scalar.value)
        || (65...70).contains(scalar.value)
        || (97...102).contains(scalar.value)
    }
  }

  private static func isBoundedNonEmpty(_ value: String, maxBytes: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == value && !value.isEmpty && value.utf8.count <= maxBytes
  }

  private static func digest(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(value)
    return "sha256:" + sha256Hex(data)
  }
}

private final class CoreAgentAppleComputerUseApprovedPlans: @unchecked Sendable {
  private let lock = NSLock()
  private let maxEntryCount = 4_096
  private var approvedPlanKeys: Set<String> = []
  private var approvedPlanOrder: [String] = []

  func record(actionID: String, digest: String) {
    lock.withLock {
      let planKey = key(actionID: actionID, digest: digest)
      guard approvedPlanKeys.insert(planKey).inserted else {
        return
      }
      approvedPlanOrder.append(planKey)
      while approvedPlanOrder.count > maxEntryCount {
        approvedPlanKeys.remove(approvedPlanOrder.removeFirst())
      }
    }
  }

  func contains(actionID: String, digest: String) -> Bool {
    lock.withLock {
      approvedPlanKeys.contains(key(actionID: actionID, digest: digest))
    }
  }

  private func key(actionID: String, digest: String) -> String {
    "\(actionID.utf8.count):\(actionID)|\(digest.utf8.count):\(digest)"
  }
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
