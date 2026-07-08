import CoreAgent
import CoreAgentGraph
import CryptoKit
import Foundation
import FoundationModels

public struct CoreAgentDeepHITLEditedAction: Codable, Equatable, Sendable {
  public let name: String
  public let argsJSON: String

  public init(name: String, argsJSON: String) {
    self.name = name
    self.argsJSON = argsJSON
  }

  enum CodingKeys: String, CodingKey {
    case name
    case argsJSON = "args_json"
  }
}

public struct CoreAgentDeepHITLActionIdentity: Codable, Equatable, Hashable, Sendable {
  public let toolCallID: String
  public let actionDigest: String

  public init(toolCallID: String, actionDigest: String) {
    self.toolCallID = toolCallID
    self.actionDigest = actionDigest
  }

  enum CodingKeys: String, CodingKey {
    case toolCallID = "tool_call_id"
    case actionDigest = "action_digest"
  }
}

public struct CoreAgentDeepHITLBatchDecision: Codable, Equatable, Sendable {
  public let action: CoreAgentDeepHITLActionIdentity
  public let type: CoreAgentDeepHITLDecisionType
  public let editedAction: CoreAgentDeepHITLEditedAction?
  public let message: String?

  public init(
    action: CoreAgentDeepHITLActionIdentity,
    type: CoreAgentDeepHITLDecisionType,
    editedAction: CoreAgentDeepHITLEditedAction? = nil,
    message: String? = nil
  ) {
    self.action = action
    self.type = type
    self.editedAction = editedAction
    self.message = message
  }

  public static func approve(action: CoreAgentDeepHITLActionIdentity) -> Self {
    Self(action: action, type: .approve)
  }

  public static func edit(
    action: CoreAgentDeepHITLActionIdentity,
    name: String,
    argsJSON: String
  ) -> Self {
    Self(
      action: action,
      type: .edit,
      editedAction: CoreAgentDeepHITLEditedAction(name: name, argsJSON: argsJSON)
    )
  }

  public static func reject(
    action: CoreAgentDeepHITLActionIdentity,
    message: String? = nil
  ) -> Self {
    Self(action: action, type: .reject, message: message)
  }

  public static func respond(
    action: CoreAgentDeepHITLActionIdentity,
    message: String
  ) -> Self {
    Self(action: action, type: .respond, message: message)
  }

  enum CodingKeys: String, CodingKey {
    case action
    case type
    case editedAction = "edited_action"
    case message
  }
}

public struct CoreAgentDeepHITLBatchResume: Codable, Equatable, Sendable {
  public let interruptID: CoreAgentGraphInterruptID
  public let decisions: [CoreAgentDeepHITLBatchDecision]

  public init(
    interruptID: CoreAgentGraphInterruptID,
    decisions: [CoreAgentDeepHITLBatchDecision]
  ) {
    self.interruptID = interruptID
    self.decisions = decisions
  }

  enum CodingKeys: String, CodingKey {
    case interruptID = "interrupt_id"
    case decisions
  }
}

public enum CoreAgentDeepHITLExecutionSource: String, Codable, Equatable, Sendable {
  case approve
  case edit
}

public struct CoreAgentDeepHITLEditedTargetAuthorization: Equatable, Sendable {
  public let reviewedActionName: String
  public let editedActionName: String
  public let allowedEditedActionNames: Set<String>
  public let reviewedActionIdentity: CoreAgentDeepHITLActionIdentity

  fileprivate init(
    reviewedActionName: String,
    editedActionName: String,
    allowedEditedActionNames: Set<String>,
    reviewedActionIdentity: CoreAgentDeepHITLActionIdentity
  ) {
    self.reviewedActionName = reviewedActionName
    self.editedActionName = editedActionName
    self.allowedEditedActionNames = allowedEditedActionNames
    self.reviewedActionIdentity = reviewedActionIdentity
  }
}

public struct CoreAgentDeepHITLExecutableAction: Equatable, Sendable {
  public let name: String
  public let argsJSON: String
  public let description: String
  public let toolCallID: String
  public let source: CoreAgentDeepHITLExecutionSource
  public let requestedName: String
  public let requestedArgsJSON: String
  public let reviewedActionIdentity: CoreAgentDeepHITLActionIdentity?
  public let editedTargetAuthorization: CoreAgentDeepHITLEditedTargetAuthorization?

  fileprivate init(
    name: String,
    argsJSON: String,
    description: String,
    toolCallID: String,
    source: CoreAgentDeepHITLExecutionSource,
    requestedName: String? = nil,
    requestedArgsJSON: String? = nil,
    reviewedActionIdentity: CoreAgentDeepHITLActionIdentity? = nil,
    editedTargetAuthorization: CoreAgentDeepHITLEditedTargetAuthorization? = nil
  ) {
    let effectiveRequestedName =
      requestedName ?? editedTargetAuthorization?.reviewedActionName ?? name
    let effectiveReviewedIdentity =
      reviewedActionIdentity ?? editedTargetAuthorization?.reviewedActionIdentity
    if let editedTargetAuthorization {
      precondition(
        editedTargetAuthorization.reviewedActionName == effectiveRequestedName,
        "Edited-target authorization must match the requested action name."
      )
      precondition(
        editedTargetAuthorization.editedActionName == name,
        "Edited-target authorization must match the executable action name."
      )
    }
    precondition(
      effectiveRequestedName == name || editedTargetAuthorization != nil,
      "Retargeted executable actions require edited-target authorization."
    )
    self.name = name
    self.argsJSON = argsJSON
    self.description = description
    self.toolCallID = toolCallID
    self.source = source
    self.requestedName = effectiveRequestedName
    self.requestedArgsJSON = requestedArgsJSON ?? argsJSON
    self.reviewedActionIdentity = effectiveReviewedIdentity
    self.editedTargetAuthorization = editedTargetAuthorization
  }

  public var executableName: String { name }
  public var executableArgsJSON: String { argsJSON }
}

public struct CoreAgentDeepHITLSyntheticToolOutput: Equatable, Sendable {
  public let name: String
  public let toolCallID: String
  public let decision: CoreAgentDeepHITLDecisionType
  public let message: String

  public init(
    name: String,
    toolCallID: String,
    decision: CoreAgentDeepHITLDecisionType,
    message: String
  ) {
    self.name = name
    self.toolCallID = toolCallID
    self.decision = decision
    self.message = message
  }
}

public enum CoreAgentDeepHITLBatchResolution: Equatable, Sendable {
  case execute(CoreAgentDeepHITLExecutableAction)
  case syntheticToolOutput(CoreAgentDeepHITLSyntheticToolOutput)
}

public struct CoreAgentDeepHITLBatchReviewRequest: Sendable {
  public let interruptID: CoreAgentGraphInterruptID
  public let toolRequests: [CoreAgentToolRequest]
  public let bundle: CoreAgentDeepHITLReviewBundle
  public let actionIdentities: [CoreAgentDeepHITLActionIdentity]

  public init(
    interruptID: CoreAgentGraphInterruptID,
    toolRequests: [CoreAgentToolRequest],
    bundle: CoreAgentDeepHITLReviewBundle,
    actionIdentities: [CoreAgentDeepHITLActionIdentity]
  ) {
    self.interruptID = interruptID
    self.toolRequests = toolRequests
    self.bundle = bundle
    self.actionIdentities = actionIdentities
  }
}

public protocol CoreAgentDeepHITLBatchReviewer: Sendable {
  func decide(_ request: CoreAgentDeepHITLBatchReviewRequest) async throws
    -> [CoreAgentDeepHITLBatchDecision]
}

public struct ClosureCoreAgentDeepHITLBatchReviewer: CoreAgentDeepHITLBatchReviewer {
  private let handler:
    @Sendable (CoreAgentDeepHITLBatchReviewRequest) async throws
      -> [CoreAgentDeepHITLBatchDecision]

  public init(
    _ handler:
      @escaping @Sendable (CoreAgentDeepHITLBatchReviewRequest) async throws
      -> [CoreAgentDeepHITLBatchDecision]
  ) {
    self.handler = handler
  }

  public func decide(_ request: CoreAgentDeepHITLBatchReviewRequest) async throws
    -> [CoreAgentDeepHITLBatchDecision]
  {
    try await handler(request)
  }
}

public struct CoreAgentDeepNativeToolBatchDecision: Sendable {
  public let request: CoreAgentToolRequest
  public let decision: CoreAgentToolInterventionDecision
  public let actionIdentity: CoreAgentDeepHITLActionIdentity?

  public init(
    request: CoreAgentToolRequest,
    decision: CoreAgentToolInterventionDecision,
    actionIdentity: CoreAgentDeepHITLActionIdentity? = nil
  ) {
    self.request = request
    self.decision = decision
    self.actionIdentity = actionIdentity
  }

  public var toolCallID: String {
    request.invocationID.uuidString.lowercased()
  }

  public var wasReviewed: Bool {
    actionIdentity != nil
  }
}

public struct CoreAgentDeepNativeToolBatchHITLAdapter: Sendable {
  public static let defaultInterruptID =
    CoreAgentGraphInterruptID("coreagent-deep-native-hitl")

  private let interruptOn: [String: CoreAgentDeepHITLRule]
  private let reviewer: any CoreAgentDeepHITLBatchReviewer

  public init(
    interruptOn: [String: CoreAgentDeepHITLRule],
    reviewer: any CoreAgentDeepHITLBatchReviewer
  ) {
    self.interruptOn = interruptOn
    self.reviewer = reviewer
  }

  public func decide(
    _ requests: [CoreAgentToolRequest],
    interruptID: CoreAgentGraphInterruptID = Self.defaultInterruptID
  ) async throws -> [CoreAgentDeepNativeToolBatchDecision] {
    guard !requests.isEmpty else { return [] }

    var decisions = requests.map {
      CoreAgentDeepNativeToolBatchDecision(request: $0, decision: .approve)
    }
    var interrupted: [InterruptedRequest] = []
    for (index, request) in requests.enumerated() {
      guard let rule = interruptOn[request.manifest.name],
        rule.shouldInterrupt(request)
      else {
        continue
      }
      guard rule.allowedEditedActionNames.isEmpty else {
        throw CoreAgentDeepHITLError.editedToolNameUnsupportedForNativeAdapter(
          reviewed: request.manifest.name,
          edited: rule.allowedEditedActionNames.sorted().joined(separator: ",")
        )
      }
      guard !rule.allowedDecisions.isEmpty else {
        throw CoreAgentDeepHITLError.emptyAllowedDecisions(
          toolName: request.manifest.name
        )
      }
      interrupted.append(InterruptedRequest(index: index, request: request, rule: rule))
    }

    guard !interrupted.isEmpty else { return decisions }

    let bundle = CoreAgentDeepHITLReviewBundle(
      actionRequests: interrupted.map {
        CoreAgentDeepHITLReviewBuilder.actionRequest(for: $0.request, rule: $0.rule)
      },
      reviewConfigs: interrupted.map {
        CoreAgentDeepHITLReviewBuilder.reviewConfig(for: $0.request, rule: $0.rule)
      }
    )
    let actionIdentities = try CoreAgentDeepHITLBatchResolver.identities(for: bundle)
    let batchRequest = CoreAgentDeepHITLBatchReviewRequest(
      interruptID: interruptID,
      toolRequests: interrupted.map(\.request),
      bundle: bundle,
      actionIdentities: actionIdentities
    )
    let resume = CoreAgentDeepHITLBatchResume(
      interruptID: interruptID,
      decisions: try await reviewer.decide(batchRequest)
    )
    let resolutions = try CoreAgentDeepHITLBatchResolver.resolve(
      bundle: bundle,
      resume: resume,
      expectedInterruptID: interruptID
    )

    for (interruptedRequest, pair) in zip(interrupted, zip(actionIdentities, resolutions)) {
      let (identity, resolution) = pair
      decisions[interruptedRequest.index] = try CoreAgentDeepNativeToolBatchDecision(
        request: interruptedRequest.request,
        decision: toolInterventionDecision(for: resolution),
        actionIdentity: identity
      )
    }
    return decisions
  }

  private func toolInterventionDecision(
    for resolution: CoreAgentDeepHITLBatchResolution
  ) throws -> CoreAgentToolInterventionDecision {
    switch resolution {
    case .execute(let action):
      switch action.source {
      case .approve:
        return .approve
      case .edit:
        guard action.name == action.requestedName else {
          throw CoreAgentDeepHITLError.editedToolNameUnsupportedForNativeAdapter(
            reviewed: action.requestedName,
            edited: action.name
          )
        }
        return .edit(arguments: try GeneratedContent(json: action.argsJSON))
      }
    case .syntheticToolOutput(let output):
      switch output.decision {
      case .reject:
        return .reject(Prompt(output.message))
      case .respond:
        return .respond(Prompt(output.message))
      case .approve, .edit:
        throw CoreAgentDeepHITLError.invalidSyntheticBatchDecision(
          toolName: output.name,
          decision: output.decision
        )
      }
    }
  }

  private struct InterruptedRequest: Sendable {
    let index: Int
    let request: CoreAgentToolRequest
    let rule: CoreAgentDeepHITLRule
  }
}

public enum CoreAgentDeepHITLBatchResolver {
  struct BoundAction: Sendable {
    let action: CoreAgentDeepHITLActionRequest
    let config: CoreAgentDeepHITLReviewConfig
    let identity: CoreAgentDeepHITLActionIdentity
  }

  public static func identities(
    for bundle: CoreAgentDeepHITLReviewBundle
  ) throws -> [CoreAgentDeepHITLActionIdentity] {
    try boundActions(for: bundle).map(\.identity)
  }

  public static func resolve(
    bundle: CoreAgentDeepHITLReviewBundle,
    resume: CoreAgentDeepHITLBatchResume,
    expectedInterruptID: CoreAgentGraphInterruptID
  ) throws -> [CoreAgentDeepHITLBatchResolution] {
    guard resume.interruptID == expectedInterruptID else {
      throw CoreAgentDeepHITLError.resumeInterruptMismatch(
        expected: expectedInterruptID.rawValue,
        actual: resume.interruptID.rawValue
      )
    }

    let boundActions = try boundActions(for: bundle)
    guard boundActions.count == resume.decisions.count else {
      throw CoreAgentDeepHITLError.decisionCountMismatch(
        expected: boundActions.count,
        actual: resume.decisions.count
      )
    }

    var seenDecisionToolCallIDs: Set<String> = []
    return try zip(boundActions, resume.decisions).map { boundAction, decision in
      guard seenDecisionToolCallIDs.insert(decision.action.toolCallID).inserted else {
        throw CoreAgentDeepHITLError.duplicateResumeDecision(
          toolCallID: decision.action.toolCallID
        )
      }
      try validate(decision: decision, for: boundAction)
      return try resolution(for: boundAction, decision: decision)
    }
  }

  private static func boundActions(
    for bundle: CoreAgentDeepHITLReviewBundle
  ) throws -> [BoundAction] {
    guard bundle.actionRequests.count == bundle.reviewConfigs.count else {
      throw CoreAgentDeepHITLError.reviewConfigCountMismatch(
        expected: bundle.actionRequests.count,
        actual: bundle.reviewConfigs.count
      )
    }

    var seenToolCallIDs: Set<String> = []
    return try bundle.actionRequests.indices.map { index in
      let action = bundle.actionRequests[index]
      let config = bundle.reviewConfigs[index]
      guard seenToolCallIDs.insert(action.toolCallID).inserted else {
        throw CoreAgentDeepHITLError.duplicateActionRequest(toolCallID: action.toolCallID)
      }
      guard config.actionName == action.name else {
        throw CoreAgentDeepHITLError.reviewConfigActionMismatch(
          index: index,
          expected: action.name,
          actual: config.actionName
        )
      }
      return BoundAction(
        action: action,
        config: config,
        identity: try identity(for: action, config: config)
      )
    }
  }

  private static func validate(
    decision: CoreAgentDeepHITLBatchDecision,
    for boundAction: BoundAction
  ) throws {
    guard decision.action.toolCallID == boundAction.identity.toolCallID else {
      throw CoreAgentDeepHITLError.decisionActionMismatch(
        expectedToolCallID: boundAction.identity.toolCallID,
        actualToolCallID: decision.action.toolCallID
      )
    }
    guard decision.action.actionDigest == boundAction.identity.actionDigest else {
      throw CoreAgentDeepHITLError.decisionActionDigestMismatch(
        toolCallID: boundAction.identity.toolCallID
      )
    }
    guard !boundAction.config.allowedDecisions.isEmpty else {
      throw CoreAgentDeepHITLError.emptyAllowedDecisions(toolName: boundAction.action.name)
    }
    guard boundAction.config.allowedDecisions.contains(decision.type) else {
      throw CoreAgentDeepHITLError.decisionNotAllowed(
        toolName: boundAction.action.name,
        decision: decision.type
      )
    }
    switch decision.type {
    case .edit:
      guard decision.editedAction != nil else {
        throw CoreAgentDeepHITLError.missingEditedAction(toolName: boundAction.action.name)
      }
    case .approve, .reject, .respond:
      guard decision.editedAction == nil else {
        throw CoreAgentDeepHITLError.unexpectedEditedAction(
          toolName: boundAction.action.name,
          decision: decision.type
        )
      }
    }
  }

  private static func resolution(
    for boundAction: BoundAction,
    decision: CoreAgentDeepHITLBatchDecision
  ) throws -> CoreAgentDeepHITLBatchResolution {
    let action = boundAction.action
    switch decision.type {
    case .approve:
      return .execute(
        CoreAgentDeepHITLExecutableAction(
          name: action.name,
          argsJSON: action.argsJSON,
          description: action.description,
          toolCallID: action.toolCallID,
          source: .approve,
          requestedName: action.name,
          requestedArgsJSON: action.argsJSON,
          reviewedActionIdentity: boundAction.identity
        )
      )
    case .edit:
      guard let editedAction = decision.editedAction else {
        throw CoreAgentDeepHITLError.missingEditedAction(toolName: action.name)
      }
      let editedTargetAuthorization: CoreAgentDeepHITLEditedTargetAuthorization?
      if editedAction.name == action.name {
        editedTargetAuthorization = nil
      } else {
        guard boundAction.config.allowedEditedActionNames.contains(editedAction.name) else {
          throw CoreAgentDeepHITLError.editedToolNameNotAllowed(
            reviewed: action.name,
            edited: editedAction.name,
            allowedEditedActionNames: boundAction.config.allowedEditedActionNames
          )
        }
        editedTargetAuthorization = CoreAgentDeepHITLEditedTargetAuthorization(
          reviewedActionName: action.name,
          editedActionName: editedAction.name,
          allowedEditedActionNames: boundAction.config.allowedEditedActionNames,
          reviewedActionIdentity: boundAction.identity
        )
      }
      return .execute(
        CoreAgentDeepHITLExecutableAction(
          name: editedAction.name,
          argsJSON: editedAction.argsJSON,
          description: action.description,
          toolCallID: action.toolCallID,
          source: .edit,
          requestedName: action.name,
          requestedArgsJSON: action.argsJSON,
          reviewedActionIdentity: boundAction.identity,
          editedTargetAuthorization: editedTargetAuthorization
        )
      )
    case .reject:
      return .syntheticToolOutput(
        CoreAgentDeepHITLSyntheticToolOutput(
          name: action.name,
          toolCallID: action.toolCallID,
          decision: .reject,
          message: decision.message ?? CoreAgentDeepHITLPolicy.defaultRejectionMessage
        )
      )
    case .respond:
      guard let message = decision.message, !message.isEmpty else {
        throw CoreAgentDeepHITLError.missingResponseMessage(
          toolName: action.name,
          decision: .respond
        )
      }
      return .syntheticToolOutput(
        CoreAgentDeepHITLSyntheticToolOutput(
          name: action.name,
          toolCallID: action.toolCallID,
          decision: .respond,
          message: message
        )
      )
    }
  }

  private static func identity(
    for action: CoreAgentDeepHITLActionRequest,
    config: CoreAgentDeepHITLReviewConfig
  ) throws -> CoreAgentDeepHITLActionIdentity {
    let payload = DigestPayload(
      digestVersion: 1,
      actionName: action.name,
      argsJSON: action.argsJSON,
      description: action.description,
      toolCallID: action.toolCallID,
      configActionName: config.actionName,
      allowedDecisions: config.allowedDecisions.map(\.rawValue).sorted(),
      allowedEditedActionNames: config.allowedEditedActionNames.sorted(),
      configDescription: config.description
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return CoreAgentDeepHITLActionIdentity(
      toolCallID: action.toolCallID,
      actionDigest: digest
    )
  }

  private struct DigestPayload: Encodable {
    let digestVersion: Int
    let actionName: String
    let argsJSON: String
    let description: String
    let toolCallID: String
    let configActionName: String
    let allowedDecisions: [String]
    let allowedEditedActionNames: [String]
    let configDescription: String?
  }
}

extension CoreAgentGraphRuntimeContext {
  public func requestDeepHITLReview(
    _ bundle: CoreAgentDeepHITLReviewBundle,
    id: CoreAgentGraphInterruptID? = nil
  ) throws -> [CoreAgentDeepHITLBatchResolution] {
    let reviewID = id ?? defaultDeepHITLReviewID
    guard let encodedResume = command?.resumeValue else {
      try interrupt(bundle, id: reviewID)
    }
    let resume: CoreAgentDeepHITLBatchResume
    do {
      resume = try encodedResume.decode(as: CoreAgentDeepHITLBatchResume.self)
    } catch {
      throw CoreAgentDeepHITLError.invalidBatchResumeValue(interruptID: reviewID.rawValue)
    }
    guard resume.interruptID == reviewID else {
      try interrupt(bundle, id: reviewID)
    }
    return try CoreAgentDeepHITLBatchResolver.resolve(
      bundle: bundle,
      resume: resume,
      expectedInterruptID: reviewID
    )
  }

  private var defaultDeepHITLReviewID: CoreAgentGraphInterruptID {
    guard let nodeID else { return "coreagent-deep-hitl" }
    return CoreAgentGraphInterruptID("coreagent-deep-hitl/\(nodeID.rawValue)")
  }
}
