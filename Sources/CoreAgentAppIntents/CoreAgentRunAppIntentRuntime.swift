import AppIntents
import CoreAgentApplePlatform
import CryptoKit
import Foundation

public enum CoreAgentRunAppIntentKind: String, Codable, Equatable, Sendable {
  case openRun = "CoreAgentOpenRunIntent"
  case pauseRun = "CoreAgentPauseRunIntent"
  case continueRun = "CoreAgentContinueRunIntent"
}

public struct CoreAgentRunAppIntentRuntimeRequest: Equatable, Sendable {
  public let kind: CoreAgentRunAppIntentKind
  public let runID: String

  public init(kind: CoreAgentRunAppIntentKind, runID: String) {
    self.kind = kind
    self.runID = runID
  }
}

public enum CoreAgentRunAppIntentRuntimeError: Error, Equatable, Sendable {
  case invalidRunID(CoreAgentRunAppIntentKind)
  case handlerUnavailable(CoreAgentRunAppIntentKind)
  case cancelled(CoreAgentRunAppIntentKind)
  case denied(CoreAgentRunAppIntentKind, CoreAgentAppleActionGateDenial)
  case missingCheckpoint(CoreAgentRunAppIntentKind)
  case failed(CoreAgentRunAppIntentKind, String)
}

public struct CoreAgentRunAppIntentRuntimeEnvironment: Sendable {
  public typealias ModeProvider =
    @Sendable (CoreAgentRunAppIntentRuntimeRequest)
    -> CoreAgentAppleAppIntentMode
  public typealias TargetProvider =
    @Sendable (CoreAgentRunAppIntentRuntimeRequest)
    -> CoreAgentAppleAppIntentExecutionTarget
  public typealias ConsentProvider =
    @Sendable (CoreAgentRunAppIntentRuntimeRequest)
    -> CoreAgentAppleConsent
  public typealias CheckpointKeyProvider =
    @Sendable (CoreAgentRunAppIntentRuntimeRequest)
    -> String?
  public typealias Operation = @Sendable (CoreAgentRunAppIntentRuntimeRequest) async throws -> Void

  public let bridge: CoreAgentAppIntentBridge
  public let mode: ModeProvider
  public let target: TargetProvider
  public let consent: ConsentProvider
  public let checkpointKey: CheckpointKeyProvider
  public let operation: Operation

  public init(
    bridge: CoreAgentAppIntentBridge,
    mode: @escaping ModeProvider,
    target: @escaping TargetProvider,
    consent: @escaping ConsentProvider,
    checkpointKey: @escaping CheckpointKeyProvider,
    operation: @escaping Operation
  ) {
    self.bridge = bridge
    self.mode = mode
    self.target = target
    self.consent = consent
    self.checkpointKey = checkpointKey
    self.operation = operation
  }
}

public actor CoreAgentRunAppIntentRuntime {
  public static let shared = CoreAgentRunAppIntentRuntime()
  private static let maxRunIDBytes = 128

  private var environment: CoreAgentRunAppIntentRuntimeEnvironment?

  public init(environment: CoreAgentRunAppIntentRuntimeEnvironment? = nil) {
    self.environment = environment
  }

  public func setEnvironment(_ environment: CoreAgentRunAppIntentRuntimeEnvironment) {
    self.environment = environment
  }

  public func resetEnvironment() {
    environment = nil
  }

  public func perform(_ request: CoreAgentRunAppIntentRuntimeRequest) async throws {
    guard Self.isValidRunID(request.runID) else {
      throw CoreAgentRunAppIntentRuntimeError.invalidRunID(request.kind)
    }
    guard !Task.isCancelled else {
      throw CoreAgentRunAppIntentRuntimeError.cancelled(request.kind)
    }
    guard let environment else {
      throw CoreAgentRunAppIntentRuntimeError.handlerUnavailable(request.kind)
    }
    let mode = environment.mode(request)
    let target = environment.target(request)
    let descriptor = Self.descriptor(for: request.kind)
    let bridgeRequest = CoreAgentAppIntentBridgeRequest(
      actionID: "\(request.kind.rawValue):\(request.runID)",
      descriptor: descriptor,
      mode: mode,
      target: target,
      consent: environment.consent(request),
      checkpointKey: environment.checkpointKey(request)
    )
    let result = await environment.bridge.perform(bridgeRequest) { _ in
      try await environment.operation(request)
      return CoreAgentAppIntentBridgeOperationResult()
    }
    switch result.status {
    case .completed:
      return
    case .cancelled:
      throw CoreAgentRunAppIntentRuntimeError.cancelled(request.kind)
    case .denied(let denial):
      throw CoreAgentRunAppIntentRuntimeError.denied(request.kind, denial)
    case .missingCheckpoint:
      throw CoreAgentRunAppIntentRuntimeError.missingCheckpoint(request.kind)
    case .failed(let reason):
      throw CoreAgentRunAppIntentRuntimeError.failed(request.kind, reason)
    }
  }

  static func isValidRunID(_ runID: String) -> Bool {
    let trimmed = runID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed == runID && !runID.isEmpty && runID.utf8.count <= maxRunIDBytes else {
      return false
    }
    guard let first = runID.unicodeScalars.first, isASCIIAlphanumeric(first) else {
      return false
    }
    return runID.unicodeScalars.allSatisfy { scalar in
      isASCIIAlphanumeric(scalar)
        || scalar.value == 45
        || scalar.value == 46
        || scalar.value == 95
    }
  }

  private static func descriptor(
    for kind: CoreAgentRunAppIntentKind
  ) -> CoreAgentAppIntentDescriptor {
    switch kind {
    case .openRun:
      CoreAgentOpenRunIntent.coreAgentDescriptor
    case .pauseRun:
      CoreAgentPauseRunIntent.coreAgentDescriptor
    case .continueRun:
      CoreAgentContinueRunIntent.coreAgentDescriptor
    }
  }

  private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    (48...57).contains(scalar.value)
      || (65...90).contains(scalar.value)
      || (97...122).contains(scalar.value)
  }
}

public struct CoreAgentOpenRunIntent: AppIntent {
  public static let title = LocalizedStringResource("Open CoreAgent Run")
  public static let supportedModes: IntentModes = .foreground(.immediate)
  public static let allowedExecutionTargets: IntentExecutionTargets = .main
  public static let coreAgentDescriptor = CoreAgentAppIntentDescriptor(
    identifier: CoreAgentRunAppIntentKind.openRun.rawValue,
    title: "Open CoreAgent Run",
    mutability: .readOnly,
    allowsAgentExecution: true,
    allowedExecutionTargets: [.foreground],
    supportedModes: [.app, .siri, .spotlight],
    donationPolicy: .doNotDonate,
    requiresAuthorization: false,
    requiresHITLForSensitiveOperations: false
  )
  public static var coreAgentOSPolicy: CoreAgentAppIntentOSPolicy {
    get throws {
      try CoreAgentAppIntentOSPolicyMapper.policy(
        for: coreAgentDescriptor,
        supportedModes: supportedModes,
        allowedExecutionTargets: allowedExecutionTargets
      )
    }
  }

  @Parameter(title: "Run ID")
  public var runID: String

  public init() {
    self.runID = ""
  }

  public init(runID: String) {
    self.runID = runID
  }

  public func perform() async throws -> some IntentResult {
    try await CoreAgentRunAppIntentRuntime.shared.perform(
      CoreAgentRunAppIntentRuntimeRequest(kind: .openRun, runID: runID)
    )
    return .result()
  }
}

public struct CoreAgentPauseRunIntent: AppIntent, CancellableIntent {
  public static let title = LocalizedStringResource("Pause CoreAgent Run")
  public static let supportedModes: IntentModes = .foreground(.dynamic)
  public static let allowedExecutionTargets: IntentExecutionTargets = .main
  public static let coreAgentDescriptor = CoreAgentAppIntentDescriptor(
    identifier: CoreAgentRunAppIntentKind.pauseRun.rawValue,
    title: "Pause CoreAgent Run",
    mutability: .mutating,
    allowsAgentExecution: true,
    allowedExecutionTargets: [.foreground],
    supportedModes: [.app, .siri, .shortcuts],
    donationPolicy: .donateAfterUserInitiatedAction,
    requiresAuthorization: true,
    requiresHITLForSensitiveOperations: true
  )
  public static var coreAgentOSPolicy: CoreAgentAppIntentOSPolicy {
    get throws {
      try CoreAgentAppIntentOSPolicyMapper.policy(
        for: coreAgentDescriptor,
        supportedModes: supportedModes,
        allowedExecutionTargets: allowedExecutionTargets
      )
    }
  }

  @Parameter(title: "Run ID")
  public var runID: String

  public init() {
    self.runID = ""
  }

  public init(runID: String) {
    self.runID = runID
  }

  public func perform() async throws -> some IntentResult {
    try await CoreAgentRunAppIntentRuntime.shared.perform(
      CoreAgentRunAppIntentRuntimeRequest(kind: .pauseRun, runID: runID)
    )
    return .result()
  }
}

public struct CoreAgentContinueRunIntent: AppIntent, CancellableIntent {
  public static let title = LocalizedStringResource("Continue CoreAgent Run")
  public static let supportedModes: IntentModes = .foreground(.dynamic)
  public static let allowedExecutionTargets: IntentExecutionTargets = .main
  public static let coreAgentDescriptor = CoreAgentAppIntentDescriptor(
    identifier: CoreAgentRunAppIntentKind.continueRun.rawValue,
    title: "Continue CoreAgent Run",
    mutability: .mutating,
    allowsAgentExecution: true,
    allowedExecutionTargets: [.foreground],
    supportedModes: [.app, .siri, .shortcuts],
    donationPolicy: .donateAfterUserInitiatedAction,
    requiresAuthorization: true,
    requiresHITLForSensitiveOperations: true
  )
  public static var coreAgentOSPolicy: CoreAgentAppIntentOSPolicy {
    get throws {
      try CoreAgentAppIntentOSPolicyMapper.policy(
        for: coreAgentDescriptor,
        supportedModes: supportedModes,
        allowedExecutionTargets: allowedExecutionTargets
      )
    }
  }

  @Parameter(title: "Run ID")
  public var runID: String

  public init() {
    self.runID = ""
  }

  public init(runID: String) {
    self.runID = runID
  }

  public func perform() async throws -> some IntentResult {
    try await CoreAgentRunAppIntentRuntime.shared.perform(
      CoreAgentRunAppIntentRuntimeRequest(kind: .continueRun, runID: runID)
    )
    return .result()
  }
}
