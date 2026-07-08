import AppIntents
import CoreAgentApplePlatform
import CryptoKit
import Foundation

public struct CoreAgentAppIntentsPackage: AppIntentsPackage {
  public init() {}
}

public struct CoreAgentAppIntentOSPolicy: Equatable, Sendable {
  public let descriptorIdentifier: String
  public let supportedModes: IntentModes
  public let allowedExecutionTargets: IntentExecutionTargets

  public init(
    descriptorIdentifier: String,
    supportedModes: IntentModes,
    allowedExecutionTargets: IntentExecutionTargets
  ) {
    self.descriptorIdentifier = descriptorIdentifier
    self.supportedModes = supportedModes
    self.allowedExecutionTargets = allowedExecutionTargets
  }
}

public struct CoreAgentRunAppIntentCatalogEntry: Equatable, Sendable {
  public let kind: CoreAgentRunAppIntentKind
  public let descriptor: CoreAgentAppIntentDescriptor
  public let osPolicy: CoreAgentAppIntentOSPolicy

  public init(
    kind: CoreAgentRunAppIntentKind,
    descriptor: CoreAgentAppIntentDescriptor,
    osPolicy: CoreAgentAppIntentOSPolicy
  ) {
    self.kind = kind
    self.descriptor = descriptor
    self.osPolicy = osPolicy
  }
}

public enum CoreAgentRunAppIntentCatalog {
  public static var entries: [CoreAgentRunAppIntentCatalogEntry] {
    get throws {
      [
        CoreAgentRunAppIntentCatalogEntry(
          kind: .openRun,
          descriptor: CoreAgentOpenRunIntent.coreAgentDescriptor,
          osPolicy: try CoreAgentOpenRunIntent.coreAgentOSPolicy
        ),
        CoreAgentRunAppIntentCatalogEntry(
          kind: .pauseRun,
          descriptor: CoreAgentPauseRunIntent.coreAgentDescriptor,
          osPolicy: try CoreAgentPauseRunIntent.coreAgentOSPolicy
        ),
        CoreAgentRunAppIntentCatalogEntry(
          kind: .continueRun,
          descriptor: CoreAgentContinueRunIntent.coreAgentDescriptor,
          osPolicy: try CoreAgentContinueRunIntent.coreAgentOSPolicy
        ),
      ]
    }
  }
}

public enum CoreAgentAppIntentOSPolicyMapper {
  public static func policy(
    for descriptor: CoreAgentAppIntentDescriptor
  ) throws -> CoreAgentAppIntentOSPolicy {
    try policy(
      for: descriptor,
      supportedModes: supportedModes(for: descriptor),
      allowedExecutionTargets: .main
    )
  }

  public static func policy(
    for descriptor: CoreAgentAppIntentDescriptor,
    supportedModes: IntentModes,
    allowedExecutionTargets: IntentExecutionTargets
  ) throws -> CoreAgentAppIntentOSPolicy {
    let validated = try descriptor.validatedForAgentExposure()
    return CoreAgentAppIntentOSPolicy(
      descriptorIdentifier: validated.identifier,
      supportedModes: supportedModes,
      allowedExecutionTargets: allowedExecutionTargets
    )
  }

  public static func supportedModes(
    for descriptor: CoreAgentAppIntentDescriptor
  ) -> IntentModes {
    switch descriptor.mutability {
    case .readOnly:
      .foreground(.deferred)
    case .mutating, .destructive:
      .foreground(.dynamic)
    }
  }
}

public struct CoreAgentAppIntentBridgeRequest: Sendable {
  public let actionID: String
  public let descriptor: CoreAgentAppIntentDescriptor
  public let mode: CoreAgentAppleAppIntentMode
  public let target: CoreAgentAppleAppIntentExecutionTarget
  public let consent: CoreAgentAppleConsent
  public let checkpointKey: String?
  public let isCancelled: @Sendable () -> Bool

  public init(
    actionID: String,
    descriptor: CoreAgentAppIntentDescriptor,
    mode: CoreAgentAppleAppIntentMode,
    target: CoreAgentAppleAppIntentExecutionTarget,
    consent: CoreAgentAppleConsent,
    checkpointKey: String? = nil,
    isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
  ) {
    self.actionID = actionID
    self.descriptor = descriptor
    self.mode = mode
    self.target = target
    self.consent = consent
    self.checkpointKey = checkpointKey
    self.isCancelled = isCancelled
  }

  public var executionRequest: CoreAgentAppleExecutionRequest {
    .appIntent(descriptor: descriptor, mode: mode, target: target)
  }
}

public struct CoreAgentAppIntentBridgeOperationResult: Equatable, Sendable {
  public init() {}
}

public enum CoreAgentAppIntentBridgeStatus: Equatable, Sendable {
  case completed
  case cancelled
  case denied(CoreAgentAppleActionGateDenial)
  case missingCheckpoint
  case failed(String)
}

public struct CoreAgentAppIntentBridgeResult: Equatable, Sendable {
  public let actionID: String
  public let descriptorIdentifier: String
  public let checkpointKey: String?
  public let status: CoreAgentAppIntentBridgeStatus

  public init(
    actionID: String,
    descriptorIdentifier: String,
    checkpointKey: String?,
    status: CoreAgentAppIntentBridgeStatus
  ) {
    self.actionID = actionID
    self.descriptorIdentifier = descriptorIdentifier
    self.checkpointKey = checkpointKey
    self.status = status
  }
}

public struct CoreAgentAppIntentBridge: Sendable {
  public typealias Checkpoint = @Sendable (CoreAgentAppIntentBridgeRequest) async throws -> Void
  public typealias Operation =
    @Sendable (CoreAgentAppIntentBridgeRequest) async throws ->
    CoreAgentAppIntentBridgeOperationResult

  public let actionGate: CoreAgentAppleActionGate
  private let checkpoint: Checkpoint

  public init(
    actionGate: CoreAgentAppleActionGate,
    checkpoint: @escaping Checkpoint = { _ in }
  ) {
    self.actionGate = actionGate
    self.checkpoint = checkpoint
  }

  public func perform(
    _ request: CoreAgentAppIntentBridgeRequest,
    operation: Operation
  ) async -> CoreAgentAppIntentBridgeResult {
    if request.isCancelled() {
      return result(for: request, status: .cancelled)
    }

    switch actionGate.evaluate(request.executionRequest, consent: request.consent) {
    case .allowed:
      break
    case .denied(let denial):
      return result(for: request, status: .denied(denial))
    }

    guard request.descriptor.mutability == .readOnly || request.checkpointKey != nil else {
      return result(for: request, status: .missingCheckpoint)
    }

    if request.checkpointKey != nil {
      do {
        try await checkpoint(request)
      } catch is CancellationError {
        return result(for: request, status: .cancelled)
      } catch {
        return result(for: request, status: .failed(String(describing: error)))
      }
      if request.isCancelled() {
        return result(for: request, status: .cancelled)
      }
    }

    if request.isCancelled() {
      return result(for: request, status: .cancelled)
    }
    do {
      _ = try await operation(request)
    } catch is CancellationError {
      return result(for: request, status: .cancelled)
    } catch {
      return result(for: request, status: .failed(String(describing: error)))
    }

    if request.isCancelled() {
      return result(for: request, status: .cancelled)
    }
    return result(for: request, status: .completed)
  }

  private func result(
    for request: CoreAgentAppIntentBridgeRequest,
    status: CoreAgentAppIntentBridgeStatus
  ) -> CoreAgentAppIntentBridgeResult {
    CoreAgentAppIntentBridgeResult(
      actionID: request.actionID,
      descriptorIdentifier: request.descriptor.identifier,
      checkpointKey: request.checkpointKey,
      status: status
    )
  }
}
