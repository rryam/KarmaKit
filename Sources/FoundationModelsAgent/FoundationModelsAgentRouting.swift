import Foundation
import FoundationModels

/// A stable, app-defined identifier for one model route.
public struct FoundationModelsAgentRouteID:
  RawRepresentable, Codable, Equatable, Hashable, Sendable, CustomStringConvertible,
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
}

/// A capability the app declares for a route.
///
/// The raw representation leaves room for provider packages to declare additional
/// capabilities without changing the router.
public struct FoundationModelsAgentRouteCapability:
  RawRepresentable, Codable, Equatable, Hashable, Sendable
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let guidedGeneration = Self(rawValue: "guided-generation")
  public static let reasoning = Self(rawValue: "reasoning")
  public static let toolCalling = Self(rawValue: "tool-calling")
  public static let vision = Self(rawValue: "vision")
}

public enum FoundationModelsAgentRoutePrivacyClass:
  String, Codable, Equatable, Hashable, Sendable
{
  /// Prompt and generated data remain on the user's device.
  case onDevice
  /// Prompt and generated data use Apple Private Cloud Compute.
  case privateCloudCompute
  /// Prompt and generated data are handled by another service.
  case thirdPartyService
}

public enum FoundationModelsAgentRouteNetworkClass:
  String, Codable, Equatable, Hashable, Sendable
{
  case none
  case applePrivateCloud
  case publicInternet
}

public enum FoundationModelsAgentRouteContextSize: Codable, Equatable, Sendable {
  case known(tokenLimit: Int)
  case unknown(reason: String)

  public var tokenLimit: Int? {
    guard case .known(let tokenLimit) = self else { return nil }
    return tokenLimit
  }
}

public enum FoundationModelsAgentRouteReasoningSupport:
  String, Codable, Equatable, Sendable
{
  case supported
  case unsupported
  case unknown
}

/// Identifies the system that meters or bills a route without carrying credentials.
public enum FoundationModelsAgentRouteAccountingProvenance: Codable, Equatable, Sendable {
  case none
  case applePrivateCloudQuota
  case externalProvider(providerID: String, accountReference: String?)
  case unknown(reason: String)

  var auditValue: String {
    switch self {
    case .none:
      "none"
    case .applePrivateCloudQuota:
      "apple-private-cloud-quota"
    case .externalProvider(let providerID, _):
      "external-provider:\(providerID)"
    case .unknown:
      "unknown"
    }
  }
}

public enum FoundationModelsAgentRouteAvailabilityState: Codable, Equatable, Sendable {
  case available
  case unavailable(code: String, explanation: String)
  case unknown(explanation: String)
}

public enum FoundationModelsAgentRouteQuotaState: Codable, Equatable, Sendable {
  case notApplicable
  case unknown(explanation: String)
  case belowLimit
  case approachingLimit
  case limitReached(resetDate: Date?, canRequestLimitIncrease: Bool)
}

/// A point-in-time availability and quota observation used for one routing decision.
public struct FoundationModelsAgentRouteAvailabilitySnapshot:
  Codable, Equatable, Sendable
{
  public let observedAt: Date
  public let state: FoundationModelsAgentRouteAvailabilityState
  public let quota: FoundationModelsAgentRouteQuotaState

  public init(
    observedAt: Date = Date(),
    state: FoundationModelsAgentRouteAvailabilityState,
    quota: FoundationModelsAgentRouteQuotaState = .notApplicable
  ) {
    self.observedAt = observedAt
    self.state = state
    self.quota = quota
  }

  /// Captures the native on-device model's current availability.
  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  @available(tvOS, unavailable)
  @available(watchOS, unavailable)
  public static func onDevice(
    _ model: SystemLanguageModel,
    observedAt: Date = Date()
  ) -> Self {
    let state: FoundationModelsAgentRouteAvailabilityState
    switch model.availability {
    case .available:
      state = .available
    case .unavailable(let reason):
      switch reason {
      case .deviceNotEligible:
        state = .unavailable(
          code: "device-not-eligible",
          explanation: "The device is not eligible for the system language model."
        )
      case .appleIntelligenceNotEnabled:
        state = .unavailable(
          code: "apple-intelligence-not-enabled",
          explanation: "Apple Intelligence is not enabled."
        )
      case .modelNotReady:
        state = .unavailable(
          code: "model-not-ready",
          explanation: "The system language model is not ready."
        )
      @unknown default:
        state = .unknown(explanation: "The system language model reported a newer state.")
      }
    }
    return Self(observedAt: observedAt, state: state)
  }

  /// Captures native Private Cloud Compute availability and quota state.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  public static func privateCloudCompute(
    _ model: PrivateCloudComputeLanguageModel,
    observedAt: Date = Date()
  ) -> Self {
    let state: FoundationModelsAgentRouteAvailabilityState
    switch model.availability {
    case .available:
      state = .available
    case .unavailable(let reason):
      switch reason {
      case .deviceNotEligible:
        state = .unavailable(
          code: "device-not-eligible",
          explanation: "The device is not eligible for Private Cloud Compute."
        )
      case .systemNotReady:
        state = .unavailable(
          code: "system-not-ready",
          explanation: "Private Cloud Compute is not ready."
        )
      @unknown default:
        state = .unknown(explanation: "Private Cloud Compute reported a newer state.")
      }
    }

    let usage = model.quotaUsage
    let quota: FoundationModelsAgentRouteQuotaState
    switch usage.status {
    case .belowLimit(let belowLimit):
      quota = belowLimit.isApproachingLimit ? .approachingLimit : .belowLimit
    case .limitReached:
      quota = .limitReached(
        resetDate: usage.resetDate,
        canRequestLimitIncrease: usage.limitIncreaseSuggestion != nil
      )
    @unknown default:
      quota = .unknown(explanation: "Private Cloud Compute reported a newer quota state.")
    }
    return Self(observedAt: observedAt, state: state, quota: quota)
  }
}

/// Codable evidence describing a route independently of its native model value.
public struct FoundationModelsAgentRouteDescriptor: Codable, Equatable, Sendable {
  public let id: FoundationModelsAgentRouteID
  public let purpose: String
  public let declaredCapabilities: [FoundationModelsAgentRouteCapability]
  public let availability: FoundationModelsAgentRouteAvailabilitySnapshot
  public let privacyClass: FoundationModelsAgentRoutePrivacyClass
  public let networkClass: FoundationModelsAgentRouteNetworkClass
  public let contextSize: FoundationModelsAgentRouteContextSize
  public let reasoningSupport: FoundationModelsAgentRouteReasoningSupport
  public let accountingProvenance: FoundationModelsAgentRouteAccountingProvenance

  public init(
    id: FoundationModelsAgentRouteID,
    purpose: String,
    declaredCapabilities: [FoundationModelsAgentRouteCapability],
    availability: FoundationModelsAgentRouteAvailabilitySnapshot,
    privacyClass: FoundationModelsAgentRoutePrivacyClass,
    networkClass: FoundationModelsAgentRouteNetworkClass,
    contextSize: FoundationModelsAgentRouteContextSize,
    reasoningSupport: FoundationModelsAgentRouteReasoningSupport,
    accountingProvenance: FoundationModelsAgentRouteAccountingProvenance
  ) {
    self.id = id
    self.purpose = purpose
    self.declaredCapabilities = Array(Set(declaredCapabilities)).sorted {
      $0.rawValue < $1.rawValue
    }
    self.availability = availability
    self.privacyClass = privacyClass
    self.networkClass = networkClass
    self.contextSize = contextSize
    self.reasoningSupport = reasoningSupport
    self.accountingProvenance = accountingProvenance
  }
}

/// One native `LanguageModel` value and the evidence used to consider it.
///
/// This is not a provider or response abstraction. The selected existential can be passed
/// directly to `AgentSession.init(model:...)` through Swift's opened existentials.
public struct FoundationModelsAgentRouteCandidate: Sendable {
  public let model: any LanguageModel
  public let descriptor: FoundationModelsAgentRouteDescriptor

  public init<Model: LanguageModel>(
    model: Model,
    descriptor: FoundationModelsAgentRouteDescriptor
  ) {
    self.model = model
    self.descriptor = descriptor
  }
}

extension FoundationModelsAgentRouteCandidate {
  /// Builds a candidate from native on-device model state.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
  @available(tvOS, unavailable)
  @available(watchOS, unavailable)
  public static func onDevice(
    id: FoundationModelsAgentRouteID,
    purpose: String,
    model: SystemLanguageModel = .default,
    observedAt: Date = Date()
  ) -> Self {
    let capabilities = Self.declaredCapabilities(of: model.capabilities)
    return Self(
      model: model,
      descriptor: FoundationModelsAgentRouteDescriptor(
        id: id,
        purpose: purpose,
        declaredCapabilities: capabilities,
        availability: .onDevice(model, observedAt: observedAt),
        privacyClass: .onDevice,
        networkClass: .none,
        contextSize: .known(tokenLimit: model.contextSize),
        reasoningSupport: capabilities.contains(.reasoning) ? .supported : .unsupported,
        accountingProvenance: .none
      )
    )
  }

  /// Builds a candidate from native Private Cloud Compute state.
  ///
  /// `contextSize` is queried only when the native availability snapshot is available.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  public static func privateCloudCompute(
    id: FoundationModelsAgentRouteID,
    purpose: String,
    model: PrivateCloudComputeLanguageModel = .init(),
    observedAt: Date = Date()
  ) async -> Self {
    let availability = FoundationModelsAgentRouteAvailabilitySnapshot.privateCloudCompute(
      model,
      observedAt: observedAt
    )
    let contextSize: FoundationModelsAgentRouteContextSize
    switch availability.state {
    case .available:
      do {
        contextSize = .known(tokenLimit: try await model.contextSize)
      } catch {
        contextSize = .unknown(
          reason: "The native Private Cloud Compute context size query failed: \(error)"
        )
      }
    case .unavailable, .unknown:
      contextSize = .unknown(
        reason: "Context size was not queried because Private Cloud Compute is unavailable."
      )
    }
    let capabilities = Self.declaredCapabilities(of: model.capabilities)
    return Self(
      model: model,
      descriptor: FoundationModelsAgentRouteDescriptor(
        id: id,
        purpose: purpose,
        declaredCapabilities: capabilities,
        availability: availability,
        privacyClass: .privateCloudCompute,
        networkClass: .applePrivateCloud,
        contextSize: contextSize,
        reasoningSupport: capabilities.contains(.reasoning) ? .supported : .unsupported,
        accountingProvenance: .applePrivateCloudQuota
      )
    )
  }

  private static func declaredCapabilities(
    of capabilities: LanguageModelCapabilities
  ) -> [FoundationModelsAgentRouteCapability] {
    [
      capabilities.contains(.guidedGeneration) ? .guidedGeneration : nil,
      capabilities.contains(.reasoning) ? .reasoning : nil,
      capabilities.contains(.toolCalling) ? .toolCalling : nil,
      capabilities.contains(.vision) ? .vision : nil,
    ].compactMap { $0 }
  }
}

public struct FoundationModelsAgentRouteDataPolicy: Codable, Equatable, Sendable {
  public let allowedPrivacyClasses: [FoundationModelsAgentRoutePrivacyClass]
  public let allowedNetworkClasses: [FoundationModelsAgentRouteNetworkClass]

  public init(
    allowedPrivacyClasses: [FoundationModelsAgentRoutePrivacyClass],
    allowedNetworkClasses: [FoundationModelsAgentRouteNetworkClass]
  ) {
    self.allowedPrivacyClasses = Array(Set(allowedPrivacyClasses)).sorted {
      $0.rawValue < $1.rawValue
    }
    self.allowedNetworkClasses = Array(Set(allowedNetworkClasses)).sorted {
      $0.rawValue < $1.rawValue
    }
  }

  /// The safe default never moves prompt data off-device.
  public static let onDeviceOnly = Self(
    allowedPrivacyClasses: [.onDevice],
    allowedNetworkClasses: [.none]
  )
}

public enum FoundationModelsAgentRouteQuotaPolicy: String, Codable, Equatable, Sendable {
  case allowApproachingLimit
  case avoidApproachingLimit
}

public struct FoundationModelsAgentRouteRequirements: Codable, Equatable, Sendable {
  public let dataPolicy: FoundationModelsAgentRouteDataPolicy
  public let minimumContextTokens: Int?
  public let requiresReasoning: Bool
  public let quotaPolicy: FoundationModelsAgentRouteQuotaPolicy

  public init(
    dataPolicy: FoundationModelsAgentRouteDataPolicy = .onDeviceOnly,
    minimumContextTokens: Int? = nil,
    requiresReasoning: Bool = false,
    quotaPolicy: FoundationModelsAgentRouteQuotaPolicy = .allowApproachingLimit
  ) {
    self.dataPolicy = dataPolicy
    self.minimumContextTokens = minimumContextTokens
    self.requiresReasoning = requiresReasoning
    self.quotaPolicy = quotaPolicy
  }
}

/// The app-supplied primary route and explicit fallback order.
public struct FoundationModelsAgentRoutePlan: Codable, Equatable, Sendable {
  public let primaryRouteID: FoundationModelsAgentRouteID
  public let fallbackRouteIDs: [FoundationModelsAgentRouteID]

  public init(
    primaryRouteID: FoundationModelsAgentRouteID,
    fallbackRouteIDs: [FoundationModelsAgentRouteID] = []
  ) {
    self.primaryRouteID = primaryRouteID
    var seen = Set([primaryRouteID])
    self.fallbackRouteIDs = fallbackRouteIDs.filter { seen.insert($0).inserted }
  }

  public var orderedRouteIDs: [FoundationModelsAgentRouteID] {
    [primaryRouteID] + fallbackRouteIDs
  }
}

/// Supplies deterministic application policy. The router does not infer a fallback.
public protocol FoundationModelsAgentRoutingPolicy: Sendable {
  func plan(
    for requirements: FoundationModelsAgentRouteRequirements,
    candidates: [FoundationModelsAgentRouteDescriptor]
  ) -> FoundationModelsAgentRoutePlan
}

public struct ClosureFoundationModelsAgentRoutingPolicy: FoundationModelsAgentRoutingPolicy {
  private let makePlan:
    @Sendable (
      FoundationModelsAgentRouteRequirements, [FoundationModelsAgentRouteDescriptor]
    ) -> FoundationModelsAgentRoutePlan

  public init(
    _ makePlan:
      @escaping @Sendable (
        FoundationModelsAgentRouteRequirements, [FoundationModelsAgentRouteDescriptor]
      ) -> FoundationModelsAgentRoutePlan
  ) {
    self.makePlan = makePlan
  }

  public func plan(
    for requirements: FoundationModelsAgentRouteRequirements,
    candidates: [FoundationModelsAgentRouteDescriptor]
  ) -> FoundationModelsAgentRoutePlan {
    makePlan(requirements, candidates)
  }
}

public enum FoundationModelsAgentRouteRejectionCode:
  String, Codable, Equatable, Sendable
{
  case duplicateRouteID
  case notIncludedInPlan
  case unavailable
  case availabilityUnknown
  case privacyDenied
  case networkDenied
  case contextSizeUnknown
  case insufficientContext
  case reasoningUnsupported
  case reasoningSupportUnknown
  case quotaUnknown
  case quotaApproachingLimit
  case quotaLimitReached
  case lowerPriorityThanSelected
}

public struct FoundationModelsAgentRouteRejectionReason: Codable, Equatable, Sendable {
  public let code: FoundationModelsAgentRouteRejectionCode
  public let explanation: String

  public init(code: FoundationModelsAgentRouteRejectionCode, explanation: String) {
    self.code = code
    self.explanation = explanation
  }
}

public enum FoundationModelsAgentRouteCandidateOutcome: Codable, Equatable, Sendable {
  case selected
  case rejected(reasons: [FoundationModelsAgentRouteRejectionReason])
}

public struct FoundationModelsAgentRouteCandidateDecision:
  Codable, Equatable, Sendable
{
  public let candidate: FoundationModelsAgentRouteDescriptor
  public let outcome: FoundationModelsAgentRouteCandidateOutcome

  public init(
    candidate: FoundationModelsAgentRouteDescriptor,
    outcome: FoundationModelsAgentRouteCandidateOutcome
  ) {
    self.candidate = candidate
    self.outcome = outcome
  }
}

/// Complete, serializable routing evidence created before an `AgentSession` run.
public struct FoundationModelsAgentRouteDecision: Codable, Equatable, Sendable {
  public let decidedAt: Date
  public let requirements: FoundationModelsAgentRouteRequirements
  public let plan: FoundationModelsAgentRoutePlan
  public let selectedRouteID: FoundationModelsAgentRouteID?
  public let selectedFallback: Bool
  public let candidateDecisions: [FoundationModelsAgentRouteCandidateDecision]

  public init(
    decidedAt: Date,
    requirements: FoundationModelsAgentRouteRequirements,
    plan: FoundationModelsAgentRoutePlan,
    selectedRouteID: FoundationModelsAgentRouteID?,
    selectedFallback: Bool,
    candidateDecisions: [FoundationModelsAgentRouteCandidateDecision]
  ) {
    self.decidedAt = decidedAt
    self.requirements = requirements
    self.plan = plan
    self.selectedRouteID = selectedRouteID
    self.selectedFallback = selectedFallback
    self.candidateDecisions = candidateDecisions
  }

  public var selectedDescriptor: FoundationModelsAgentRouteDescriptor? {
    candidateDecisions.first {
      guard $0.candidate.id == selectedRouteID else { return false }
      guard case .selected = $0.outcome else { return false }
      return true
    }?.candidate
  }

  var hasExecutableSelection: Bool {
    guard let selectedRouteID,
      plan.orderedRouteIDs.contains(selectedRouteID),
      selectedFallback == (selectedRouteID != plan.primaryRouteID)
    else {
      return false
    }
    let candidateIDs = candidateDecisions.map(\.candidate.id)
    guard Set(candidateIDs).count == candidateIDs.count else { return false }
    let selected = candidateDecisions.filter {
      if case .selected = $0.outcome { return true }
      return false
    }
    guard selected.count == 1, selected.first?.candidate.id == selectedRouteID else {
      return false
    }
    return candidateDecisions.allSatisfy {
      if case .rejected(let reasons) = $0.outcome {
        return !reasons.isEmpty
      }
      return true
    }
  }
}

public struct FoundationModelsAgentRouteSelection: Sendable {
  public let model: any LanguageModel
  public let decision: FoundationModelsAgentRouteDecision

  public init(model: any LanguageModel, decision: FoundationModelsAgentRouteDecision) {
    self.model = model
    self.decision = decision
  }
}

public enum FoundationModelsAgentRouteSelectionResult: Sendable {
  case selected(FoundationModelsAgentRouteSelection)
  case noRoute(FoundationModelsAgentRouteDecision)

  public var decision: FoundationModelsAgentRouteDecision {
    switch self {
    case .selected(let selection):
      selection.decision
    case .noRoute(let decision):
      decision
    }
  }

  public var selection: FoundationModelsAgentRouteSelection? {
    guard case .selected(let selection) = self else { return nil }
    return selection
  }
}

/// Applies app policy and produces evidence. It never invokes a model.
public struct FoundationModelsAgentRouter: Sendable {
  public init() {}

  public func select(
    from candidates: [FoundationModelsAgentRouteCandidate],
    requirements: FoundationModelsAgentRouteRequirements = .init(),
    policy: some FoundationModelsAgentRoutingPolicy,
    decidedAt: Date = Date()
  ) -> FoundationModelsAgentRouteSelectionResult {
    let descriptors = candidates.map(\.descriptor)
    let plan = policy.plan(for: requirements, candidates: descriptors)
    let plannedIDs = Set(plan.orderedRouteIDs)
    let duplicateIDs = Set(
      Dictionary(grouping: descriptors.map(\.id), by: { $0 })
        .filter { $0.value.count > 1 }
        .map(\.key)
    )
    let baseRejections = Dictionary(
      uniqueKeysWithValues: candidates.enumerated().map { index, candidate in
        (
          index,
          rejectionReasons(
            for: candidate.descriptor,
            requirements: requirements,
            plannedIDs: plannedIDs,
            duplicateIDs: duplicateIDs
          )
        )
      }
    )

    let selectedIndex = plan.orderedRouteIDs.lazy.compactMap { routeID in
      candidates.indices.first {
        candidates[$0].descriptor.id == routeID && baseRejections[$0, default: []].isEmpty
      }
    }.first
    let selectedRouteID = selectedIndex.map { candidates[$0].descriptor.id }
    let selectedFallback = selectedRouteID.map { $0 != plan.primaryRouteID } ?? false

    let decisions = candidates.indices.map { index in
      let candidate = candidates[index].descriptor
      if index == selectedIndex {
        return FoundationModelsAgentRouteCandidateDecision(
          candidate: candidate,
          outcome: .selected
        )
      }
      var reasons = baseRejections[index, default: []]
      if reasons.isEmpty {
        reasons = [
          .init(
            code: .lowerPriorityThanSelected,
            explanation: "A higher-priority eligible route was selected."
          )
        ]
      }
      return FoundationModelsAgentRouteCandidateDecision(
        candidate: candidate,
        outcome: .rejected(reasons: reasons)
      )
    }
    let decision = FoundationModelsAgentRouteDecision(
      decidedAt: decidedAt,
      requirements: requirements,
      plan: plan,
      selectedRouteID: selectedRouteID,
      selectedFallback: selectedFallback,
      candidateDecisions: decisions
    )
    guard let selectedIndex else {
      return .noRoute(decision)
    }
    return .selected(
      FoundationModelsAgentRouteSelection(
        model: candidates[selectedIndex].model,
        decision: decision
      )
    )
  }

  private func rejectionReasons(
    for candidate: FoundationModelsAgentRouteDescriptor,
    requirements: FoundationModelsAgentRouteRequirements,
    plannedIDs: Set<FoundationModelsAgentRouteID>,
    duplicateIDs: Set<FoundationModelsAgentRouteID>
  ) -> [FoundationModelsAgentRouteRejectionReason] {
    var reasons: [FoundationModelsAgentRouteRejectionReason] = []
    if duplicateIDs.contains(candidate.id) {
      reasons.append(
        .init(
          code: .duplicateRouteID,
          explanation: "The candidate list contains the route ID more than once."
        )
      )
    }
    if !plannedIDs.contains(candidate.id) {
      reasons.append(
        .init(
          code: .notIncludedInPlan,
          explanation: "The app-supplied policy did not include this route."
        )
      )
    }
    switch candidate.availability.state {
    case .available:
      break
    case .unavailable(_, let explanation):
      reasons.append(.init(code: .unavailable, explanation: explanation))
    case .unknown(let explanation):
      reasons.append(.init(code: .availabilityUnknown, explanation: explanation))
    }
    if !requirements.dataPolicy.allowedPrivacyClasses.contains(candidate.privacyClass) {
      reasons.append(
        .init(
          code: .privacyDenied,
          explanation: "The route privacy class is not allowed by the request data policy."
        )
      )
    }
    if !requirements.dataPolicy.allowedNetworkClasses.contains(candidate.networkClass) {
      reasons.append(
        .init(
          code: .networkDenied,
          explanation: "The route network class is not allowed by the request data policy."
        )
      )
    }
    if let minimum = requirements.minimumContextTokens {
      switch candidate.contextSize {
      case .known(let tokenLimit) where tokenLimit < minimum:
        reasons.append(
          .init(
            code: .insufficientContext,
            explanation: "The route context limit is below the required token count."
          )
        )
      case .unknown(let explanation):
        reasons.append(.init(code: .contextSizeUnknown, explanation: explanation))
      default:
        break
      }
    }
    if requirements.requiresReasoning {
      switch candidate.reasoningSupport {
      case .supported:
        break
      case .unsupported:
        reasons.append(
          .init(
            code: .reasoningUnsupported,
            explanation: "The request requires reasoning support."
          )
        )
      case .unknown:
        reasons.append(
          .init(
            code: .reasoningSupportUnknown,
            explanation: "The route's reasoning support is unknown."
          )
        )
      }
    }
    switch candidate.availability.quota {
    case .notApplicable, .belowLimit:
      break
    case .unknown(let explanation):
      reasons.append(.init(code: .quotaUnknown, explanation: explanation))
    case .approachingLimit where requirements.quotaPolicy == .avoidApproachingLimit:
      reasons.append(
        .init(
          code: .quotaApproachingLimit,
          explanation: "The route is approaching its quota limit."
        )
      )
    case .approachingLimit:
      break
    case .limitReached:
      reasons.append(
        .init(code: .quotaLimitReached, explanation: "The route quota limit is reached.")
      )
    }
    return reasons
  }
}
