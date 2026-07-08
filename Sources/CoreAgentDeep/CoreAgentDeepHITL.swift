import CoreAgent
import Foundation
import FoundationModels

public enum CoreAgentDeepHITLDecisionType: String, Codable, CaseIterable, Hashable, Sendable {
  case approve
  case edit
  case reject
  case respond
}

public enum CoreAgentDeepHITLDecision: Sendable {
  case approve
  case edit(arguments: GeneratedContent)
  case reject(reason: String? = nil)
  case respond(message: String)

  public var type: CoreAgentDeepHITLDecisionType {
    switch self {
    case .approve:
      .approve
    case .edit:
      .edit
    case .reject:
      .reject
    case .respond:
      .respond
    }
  }
}

public enum CoreAgentDeepHITLError: Error, Equatable, LocalizedError, Sendable {
  case emptyAllowedDecisions(toolName: String)
  case decisionNotAllowed(toolName: String, decision: CoreAgentDeepHITLDecisionType)
  case decisionCountMismatch(expected: Int, actual: Int)
  case reviewConfigCountMismatch(expected: Int, actual: Int)
  case reviewConfigActionMismatch(index: Int, expected: String, actual: String)
  case missingReviewConfig(actionName: String)
  case missingEditedAction(toolName: String)
  case unexpectedEditedAction(toolName: String, decision: CoreAgentDeepHITLDecisionType)
  case missingResponseMessage(toolName: String, decision: CoreAgentDeepHITLDecisionType)
  case invalidBatchResumeValue(interruptID: String)
  case resumeInterruptMismatch(expected: String, actual: String)
  case duplicateActionRequest(toolCallID: String)
  case decisionActionMismatch(expectedToolCallID: String, actualToolCallID: String)
  case decisionActionDigestMismatch(toolCallID: String)
  case duplicateResumeDecision(toolCallID: String)
  case editedToolNameNotAllowed(
    reviewed: String,
    edited: String,
    allowedEditedActionNames: Set<String>
  )
  case editedToolNameUnsupportedForNativeAdapter(reviewed: String, edited: String)
  case invalidSyntheticBatchDecision(toolName: String, decision: CoreAgentDeepHITLDecisionType)
  case missingExecutableManifest(toolName: String)
  case duplicateExecutableManifest(toolName: String)
  case invalidRequestedArguments(toolName: String)
  case invalidExecutableArguments(toolName: String)

  public var errorDescription: String? {
    switch self {
    case .emptyAllowedDecisions(let toolName):
      "Tool '\(toolName)' has an interrupt rule with no allowed decisions."
    case .decisionNotAllowed(let toolName, let decision):
      "Tool '\(toolName)' received disallowed human-in-the-loop decision '\(decision.rawValue)'."
    case .decisionCountMismatch(let expected, let actual):
      "Human-in-the-loop resume supplied \(actual) decisions for \(expected) requested actions."
    case .reviewConfigCountMismatch(let expected, let actual):
      "Human-in-the-loop review bundle supplied \(actual) configs for \(expected) requested actions."
    case .reviewConfigActionMismatch(let index, let expected, let actual):
      "Human-in-the-loop review config at index \(index) is for '\(actual)' but expected '\(expected)'."
    case .missingReviewConfig(let actionName):
      "Human-in-the-loop action '\(actionName)' is missing a review config."
    case .missingEditedAction(let toolName):
      "Human-in-the-loop edit decision for tool '\(toolName)' is missing the edited action."
    case .unexpectedEditedAction(let toolName, let decision):
      "Human-in-the-loop \(decision.rawValue) decision for tool '\(toolName)' must not include an edited action."
    case .missingResponseMessage(let toolName, let decision):
      "Human-in-the-loop \(decision.rawValue) decision for tool '\(toolName)' is missing a response message."
    case .invalidBatchResumeValue(let interruptID):
      "Human-in-the-loop resume for interrupt '\(interruptID)' could not be decoded."
    case .resumeInterruptMismatch(let expected, let actual):
      "Human-in-the-loop resume targeted interrupt '\(actual)' but expected '\(expected)'."
    case .duplicateActionRequest(let toolCallID):
      "Human-in-the-loop review bundle contains duplicate action request '\(toolCallID)'."
    case .decisionActionMismatch(let expectedToolCallID, let actualToolCallID):
      "Human-in-the-loop decision targeted action '\(actualToolCallID)' but expected '\(expectedToolCallID)'."
    case .decisionActionDigestMismatch(let toolCallID):
      "Human-in-the-loop decision for action '\(toolCallID)' does not match the reviewed action digest."
    case .duplicateResumeDecision(let toolCallID):
      "Human-in-the-loop resume contains duplicate decision for action '\(toolCallID)'."
    case .editedToolNameNotAllowed(let reviewed, let edited, let allowedEditedActionNames):
      "Human-in-the-loop edit targeted tool '\(edited)' but review config for "
        + "'\(reviewed)' did not allow edited tool-name targets. Allowed edited targets: "
        + allowedEditedActionNames.sorted().joined(separator: ", ")
        + "."
    case .editedToolNameUnsupportedForNativeAdapter(let reviewed, let edited):
      "Human-in-the-loop edit targeted tool '\(edited)' from reviewed tool "
        + "'\(reviewed)', but native Foundation Models tool calls cannot change registered "
        + "tool names at the Tool.call boundary."
    case .invalidSyntheticBatchDecision(let toolName, let decision):
      "Human-in-the-loop batch resolver produced invalid synthetic '\(decision.rawValue)' "
        + "output for tool '\(toolName)'."
    case .missingExecutableManifest(let toolName):
      "Human-in-the-loop executable action targeted tool '\(toolName)' but no executable manifest was registered."
    case .duplicateExecutableManifest(let toolName):
      "Human-in-the-loop executable action dispatcher received duplicate executable manifest '\(toolName)'."
    case .invalidRequestedArguments(let toolName):
      "Human-in-the-loop executable action reviewed tool '\(toolName)' has invalid JSON arguments."
    case .invalidExecutableArguments(let toolName):
      "Human-in-the-loop executable action for tool '\(toolName)' has invalid JSON arguments."
    }
  }
}

public struct CoreAgentDeepHITLActionRequest: Codable, Equatable, Sendable {
  public let name: String
  public let argsJSON: String
  public let description: String
  public let toolCallID: String

  public init(
    name: String,
    argsJSON: String,
    description: String,
    toolCallID: String
  ) {
    self.name = name
    self.argsJSON = argsJSON
    self.description = description
    self.toolCallID = toolCallID
  }

  enum CodingKeys: String, CodingKey {
    case name
    case argsJSON = "args_json"
    case description
    case toolCallID = "tool_call_id"
  }
}

public struct CoreAgentDeepHITLReviewConfig: Codable, Equatable, Sendable {
  public let actionName: String
  public let allowedDecisions: Set<CoreAgentDeepHITLDecisionType>
  public let allowedEditedActionNames: Set<String>
  public let description: String?

  public init(
    actionName: String,
    allowedDecisions: Set<CoreAgentDeepHITLDecisionType>,
    allowedEditedActionNames: Set<String> = [],
    description: String? = nil
  ) {
    self.actionName = actionName
    self.allowedDecisions = allowedDecisions
    self.allowedEditedActionNames = allowedEditedActionNames
    self.description = description
  }

  enum CodingKeys: String, CodingKey {
    case actionName = "action_name"
    case allowedDecisions = "allowed_decisions"
    case allowedEditedActionNames = "allowed_edited_action_names"
    case description
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.actionName = try container.decode(String.self, forKey: .actionName)
    self.allowedDecisions = Set(
      try container.decode([CoreAgentDeepHITLDecisionType].self, forKey: .allowedDecisions)
    )
    self.allowedEditedActionNames = Set(
      try container.decodeIfPresent([String].self, forKey: .allowedEditedActionNames) ?? []
    )
    self.description = try container.decodeIfPresent(String.self, forKey: .description)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(actionName, forKey: .actionName)
    try container.encode(
      allowedDecisions.sorted { $0.rawValue < $1.rawValue },
      forKey: .allowedDecisions
    )
    try container.encode(allowedEditedActionNames.sorted(), forKey: .allowedEditedActionNames)
    try container.encodeIfPresent(description, forKey: .description)
  }
}

public struct CoreAgentDeepHITLReviewBundle: Codable, Equatable, Sendable {
  public let actionRequests: [CoreAgentDeepHITLActionRequest]
  public let reviewConfigs: [CoreAgentDeepHITLReviewConfig]

  public init(
    actionRequests: [CoreAgentDeepHITLActionRequest],
    reviewConfigs: [CoreAgentDeepHITLReviewConfig]
  ) {
    self.actionRequests = actionRequests
    self.reviewConfigs = reviewConfigs
  }

  enum CodingKeys: String, CodingKey {
    case actionRequests = "action_requests"
    case reviewConfigs = "review_configs"
  }
}

public struct CoreAgentDeepHITLReviewRequest: Sendable {
  public let toolRequest: CoreAgentToolRequest
  public let allowedDecisions: Set<CoreAgentDeepHITLDecisionType>
  public let actionRequests: [CoreAgentDeepHITLActionRequest]
  public let reviewConfigs: [CoreAgentDeepHITLReviewConfig]

  public init(
    toolRequest: CoreAgentToolRequest,
    allowedDecisions: Set<CoreAgentDeepHITLDecisionType>,
    actionRequests: [CoreAgentDeepHITLActionRequest],
    reviewConfigs: [CoreAgentDeepHITLReviewConfig]
  ) {
    self.toolRequest = toolRequest
    self.allowedDecisions = allowedDecisions
    self.actionRequests = actionRequests
    self.reviewConfigs = reviewConfigs
  }

  public var bundle: CoreAgentDeepHITLReviewBundle {
    CoreAgentDeepHITLReviewBundle(
      actionRequests: actionRequests,
      reviewConfigs: reviewConfigs
    )
  }
}

public protocol CoreAgentDeepHITLReviewer: Sendable {
  func decide(_ request: CoreAgentDeepHITLReviewRequest) async throws
    -> CoreAgentDeepHITLDecision
}

public struct ClosureCoreAgentDeepHITLReviewer: CoreAgentDeepHITLReviewer {
  private let handler:
    @Sendable (CoreAgentDeepHITLReviewRequest) async throws -> CoreAgentDeepHITLDecision

  public init(
    _ handler:
      @escaping @Sendable (CoreAgentDeepHITLReviewRequest) async throws
        -> CoreAgentDeepHITLDecision
  ) {
    self.handler = handler
  }

  public func decide(_ request: CoreAgentDeepHITLReviewRequest) async throws
    -> CoreAgentDeepHITLDecision
  {
    try await handler(request)
  }
}

enum CoreAgentDeepHITLReviewBuilder {
  static func reviewRequest(
    for request: CoreAgentToolRequest,
    rule: CoreAgentDeepHITLRule
  ) -> CoreAgentDeepHITLReviewRequest {
    let action = actionRequest(for: request, rule: rule)
    let config = reviewConfig(for: request, rule: rule)
    return CoreAgentDeepHITLReviewRequest(
      toolRequest: request,
      allowedDecisions: rule.allowedDecisions,
      actionRequests: [action],
      reviewConfigs: [config]
    )
  }

  static func actionRequest(
    for request: CoreAgentToolRequest,
    rule: CoreAgentDeepHITLRule
  ) -> CoreAgentDeepHITLActionRequest {
    CoreAgentDeepHITLActionRequest(
      name: request.manifest.name,
      argsJSON: request.argumentsJSON,
      description: rule.description ?? request.manifest.description,
      toolCallID: request.invocationID.uuidString.lowercased()
    )
  }

  static func reviewConfig(
    for request: CoreAgentToolRequest,
    rule: CoreAgentDeepHITLRule
  ) -> CoreAgentDeepHITLReviewConfig {
    CoreAgentDeepHITLReviewConfig(
      actionName: request.manifest.name,
      allowedDecisions: rule.allowedDecisions,
      allowedEditedActionNames: rule.allowedEditedActionNames,
      description: rule.description
    )
  }
}

public struct CoreAgentDeepHITLRule: Sendable {
  public typealias Predicate = @Sendable (CoreAgentToolRequest) -> Bool

  public static let defaultAllowedDecisions: Set<CoreAgentDeepHITLDecisionType> = [
    .approve,
    .edit,
    .reject,
    .respond,
  ]

  public let interrupts: Bool
  public let allowedDecisions: Set<CoreAgentDeepHITLDecisionType>
  public let allowedEditedActionNames: Set<String>
  public let description: String?
  private let predicate: Predicate?

  public init(
    interrupts: Bool,
    allowedDecisions: Set<CoreAgentDeepHITLDecisionType> = Self.defaultAllowedDecisions,
    allowedEditedActionNames: Set<String> = [],
    description: String? = nil,
    when predicate: Predicate? = nil
  ) {
    self.interrupts = interrupts
    self.allowedDecisions = allowedDecisions
    self.allowedEditedActionNames = allowedEditedActionNames
    self.description = description
    self.predicate = predicate
  }

  public static var interrupt: Self {
    interrupt()
  }

  public static func interrupt(
    allowedDecisions: Set<CoreAgentDeepHITLDecisionType> = Self.defaultAllowedDecisions,
    allowedEditedActionNames: Set<String> = [],
    description: String? = nil,
    when predicate: Predicate? = nil
  ) -> Self {
    Self(
      interrupts: true,
      allowedDecisions: allowedDecisions,
      allowedEditedActionNames: allowedEditedActionNames,
      description: description,
      when: predicate
    )
  }

  public static var never: Self {
    Self(interrupts: false)
  }

  func shouldInterrupt(_ request: CoreAgentToolRequest) -> Bool {
    guard interrupts else { return false }
    guard let predicate else { return true }
    return predicate(request)
  }
}

actor CoreAgentDeepHITLPredicateCache {
  private var approvedPrechecks: Set<Key> = []

  func storeApprovedPrecheck(for request: CoreAgentToolRequest) {
    approvedPrechecks.insert(Key(request))
  }

  func consumeApprovedPrecheck(for request: CoreAgentToolRequest) -> Bool {
    approvedPrechecks.remove(Key(request)) != nil
  }

  private struct Key: Hashable {
    let runID: UUID
    let invocationID: UUID
    let manifestDigest: String

    init(_ request: CoreAgentToolRequest) {
      self.runID = request.runID
      self.invocationID = request.invocationID
      self.manifestDigest = request.manifest.digest
    }
  }
}

public struct CoreAgentDeepHITLPolicy: CoreAgentToolInterventionPolicy {
  public static let defaultRejectionMessage =
    "User rejected this tool call. The tool was not executed. Do not retry the same tool call unless the user explicitly requests it."

  private let interruptOn: [String: CoreAgentDeepHITLRule]
  private let reviewer: any CoreAgentDeepHITLReviewer
  private let predicateCache = CoreAgentDeepHITLPredicateCache()

  public init(
    interruptOn: [String: CoreAgentDeepHITLRule],
    reviewer: any CoreAgentDeepHITLReviewer
  ) {
    self.interruptOn = interruptOn
    self.reviewer = reviewer
  }

  public func shouldIntervene(_ request: CoreAgentToolRequest) async throws -> Bool {
    guard let rule = interruptOn[request.manifest.name] else { return false }
    let shouldInterrupt = rule.shouldInterrupt(request)
    if shouldInterrupt {
      await predicateCache.storeApprovedPrecheck(for: request)
    }
    return shouldInterrupt
  }

  public func decide(_ request: CoreAgentToolRequest) async throws
    -> CoreAgentToolInterventionDecision
  {
    guard let rule = interruptOn[request.manifest.name] else {
      return .approve
    }
    let prechecked = await predicateCache.consumeApprovedPrecheck(for: request)
    guard prechecked || rule.shouldInterrupt(request) else {
      return .approve
    }
    guard !rule.allowedDecisions.isEmpty else {
      throw CoreAgentDeepHITLError.emptyAllowedDecisions(toolName: request.manifest.name)
    }
    guard rule.allowedEditedActionNames.isEmpty else {
      throw CoreAgentDeepHITLError.editedToolNameUnsupportedForNativeAdapter(
        reviewed: request.manifest.name,
        edited: rule.allowedEditedActionNames.sorted().joined(separator: ",")
      )
    }

    let reviewRequest = CoreAgentDeepHITLReviewBuilder.reviewRequest(for: request, rule: rule)
    let decision = try await reviewer.decide(reviewRequest)
    guard rule.allowedDecisions.contains(decision.type) else {
      throw CoreAgentDeepHITLError.decisionNotAllowed(
        toolName: request.manifest.name,
        decision: decision.type
      )
    }

    switch decision {
    case .approve:
      return .approve
    case .edit(let arguments):
      return .edit(arguments: arguments)
    case .reject(let reason):
      return .reject(Prompt(reason ?? Self.defaultRejectionMessage))
    case .respond(let message):
      return .respond(Prompt(message))
    }
  }

}
