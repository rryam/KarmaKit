import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CryptoKit
import Foundation
import Observation
import SwiftData

public enum CoreAgentAppleExecutionCapability: String, Codable, Hashable, Sendable {
  case deterministicCodeInterpreter
  case wasiCodeInterpreter
  case helperCodeInterpreter
  case remoteCodeInterpreter
  case computerUse
  case appIntentExecution
  case appIntentDonation
  case swiftDataCheckpointPersistence
}

public enum CoreAgentAppleNetworkPolicy: String, Codable, Equatable, Sendable {
  case denied
  case localOnly
  case allowed
}

public struct CoreAgentAppleSandboxProfile: Equatable, Sendable {
  public let capabilities: Set<CoreAgentAppleExecutionCapability>
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let authorityBoundaryID: String
  public let policyVersion: Int

  public init(
    capabilities: Set<CoreAgentAppleExecutionCapability>,
    workspaceRoot: URL,
    networkPolicy: CoreAgentAppleNetworkPolicy,
    authorityBoundaryID: String = "default",
    policyVersion: Int = 1
  ) {
    self.capabilities = capabilities
    self.workspaceRoot = workspaceRoot
    self.networkPolicy = networkPolicy
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
  }

  public func allows(_ capability: CoreAgentAppleExecutionCapability) -> Bool {
    capabilities.contains(capability)
  }
}

public enum CoreAgentAppleInterpreterTier: String, Codable, Equatable, Sendable {
  case deterministicInProcess
  case wasiWebAssembly
  case helperProcess
  case remote

  var requiredCapability: CoreAgentAppleExecutionCapability {
    switch self {
    case .deterministicInProcess:
      .deterministicCodeInterpreter
    case .wasiWebAssembly:
      .wasiCodeInterpreter
    case .helperProcess:
      .helperCodeInterpreter
    case .remote:
      .remoteCodeInterpreter
    }
  }
}

public enum CoreAgentAppleExecutionRequest: Equatable, Sendable {
  case codeInterpreter(tier: CoreAgentAppleInterpreterTier)
  case codeInterpreterInvocation(
    tier: CoreAgentAppleInterpreterTier,
    programDigest: String,
    inputDigest: String
  )
  case computerUsePlan(actionID: String)
  case computerUse(actionID: String)
  case computerUseExecution(actionID: String, approvedPlanDigest: String)
  case swiftDataCheckpointPersistence(checkpointKey: String)
  case appIntentDonation(descriptor: CoreAgentAppIntentDescriptor)
  case appIntentDonationRecord(record: CoreAgentAppIntentDonationRecord)
  case appIntentDonationInvalidation(
    record: CoreAgentAppIntentDonationRecord,
    reason: CoreAgentAppIntentDonationInvalidationReason
  )
  case appIntent(
    descriptor: CoreAgentAppIntentDescriptor,
    mode: CoreAgentAppleAppIntentMode,
    target: CoreAgentAppleAppIntentExecutionTarget
  )
}

public struct CoreAgentAppleConsentRequirement:
  Codable, Equatable, Sendable
{
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let capability: CoreAgentAppleExecutionCapability
  public let requestFingerprint: String

  public init(
    authorityBoundaryID: String,
    policyVersion: Int,
    capability: CoreAgentAppleExecutionCapability,
    requestFingerprint: String
  ) {
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.capability = capability
    self.requestFingerprint = requestFingerprint
  }
}

public struct CoreAgentAppleConsentReceipt:
  Codable, Equatable, Sendable
{
  public let id: String
  public let issuerID: String
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let capability: CoreAgentAppleExecutionCapability
  public let requestFingerprint: String
  public let grantedAt: Date
  public let expiresAt: Date?
  public let signature: String

  public init(
    id: String,
    issuerID: String,
    authorityBoundaryID: String,
    policyVersion: Int,
    capability: CoreAgentAppleExecutionCapability,
    requestFingerprint: String,
    grantedAt: Date,
    expiresAt: Date?,
    signature: String
  ) {
    self.id = id
    self.issuerID = issuerID
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.capability = capability
    self.requestFingerprint = requestFingerprint
    self.grantedAt = grantedAt
    self.expiresAt = expiresAt
    self.signature = signature
  }

  private init(
    id: String,
    issuerID: String,
    requirement: CoreAgentAppleConsentRequirement,
    grantedAt: Date,
    expiresAt: Date,
    signature: String
  ) {
    self.init(
      id: id,
      issuerID: issuerID,
      authorityBoundaryID: requirement.authorityBoundaryID,
      policyVersion: requirement.policyVersion,
      capability: requirement.capability,
      requestFingerprint: requirement.requestFingerprint,
      grantedAt: grantedAt,
      expiresAt: expiresAt,
      signature: signature
    )
  }

  public static func issue(
    id: String,
    issuerID: String,
    requirement: CoreAgentAppleConsentRequirement,
    signingKey: CoreAgentAppleConsentSigningKey,
    grantedAt: Date,
    expiresAt: Date
  ) -> CoreAgentAppleConsentReceipt {
    let unsigned = CoreAgentAppleConsentReceipt(
      id: id,
      issuerID: issuerID,
      requirement: requirement,
      grantedAt: grantedAt,
      expiresAt: expiresAt,
      signature: ""
    )
    return CoreAgentAppleConsentReceipt(
      id: id,
      issuerID: issuerID,
      requirement: requirement,
      grantedAt: grantedAt,
      expiresAt: expiresAt,
      signature: unsigned.signature(signingKey: signingKey)
    )
  }

  fileprivate func verifies(with signingKey: CoreAgentAppleConsentSigningKey) -> Bool {
    guard let authenticationCode = Self.authenticationCode(from: signature) else {
      return false
    }
    return HMAC<SHA256>.isValidAuthenticationCode(
      authenticationCode,
      authenticating: signaturePayload,
      using: SymmetricKey(data: signingKey.material)
    )
  }

  private func signature(signingKey: CoreAgentAppleConsentSigningKey) -> String {
    let mac = HMAC<SHA256>.authenticationCode(
      for: signaturePayload,
      using: SymmetricKey(data: signingKey.material)
    )
    return "hmac-sha256:" + mac.map { String(format: "%02x", $0) }.joined()
  }

  private var signaturePayload: Data {
    let fields = [
      id,
      issuerID,
      authorityBoundaryID,
      String(policyVersion),
      capability.rawValue,
      requestFingerprint,
      Self.timeToken(grantedAt),
      expiresAt.map(Self.timeToken) ?? "nil",
    ]
    return Data(fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|").utf8)
  }

  private static func authenticationCode(from signature: String) -> [UInt8]? {
    let prefix = "hmac-sha256:"
    guard signature.hasPrefix(prefix) else {
      return nil
    }
    let hex = signature.dropFirst(prefix.count)
    guard hex.count == 64 else {
      return nil
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(32)
    var index = hex.startIndex
    while index < hex.endIndex {
      let nextIndex = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
        return nil
      }
      bytes.append(byte)
      index = nextIndex
    }
    return bytes.count == 32 ? bytes : nil
  }

  private static func timeToken(_ date: Date) -> String {
    stableTimeToken(date)
  }
}

public struct CoreAgentAppleConsentSigningKey: Equatable, Sendable {
  fileprivate let material: Data

  public init?(_ material: Data) {
    guard material.count >= 32 else {
      return nil
    }
    self.material = material
  }
}

private final class CoreAgentAppleConsumedConsentReceipts: @unchecked Sendable {
  private let lock = NSLock()
  private var consumedReceiptKeys: Set<String> = []

  func consume(_ key: String) -> Bool {
    lock.withLock {
      if consumedReceiptKeys.contains(key) {
        return false
      }
      consumedReceiptKeys.insert(key)
      return true
    }
  }
}

public enum CoreAgentAppleConsent: Equatable, Sendable {
  case notRequired
  case required(reason: String)
  case granted(CoreAgentAppleConsentReceipt)
}

public enum CoreAgentAppleActionGateDenial: Equatable, Sendable {
  case missingCapability(CoreAgentAppleExecutionCapability)
  case missingConsent(CoreAgentAppleExecutionCapability)
  case remoteExecutionRequiresNetworkPolicy
  case invalidConsentReceipt(String)
  case consentAuthorityBoundaryMismatch(expected: String, actual: String)
  case consentPolicyVersionMismatch(expected: Int, actual: Int)
  case consentCapabilityMismatch(
    expected: CoreAgentAppleExecutionCapability,
    actual: CoreAgentAppleExecutionCapability
  )
  case consentRequestMismatch(expected: String, actual: String)
  case expiredConsentReceipt(String)
  case missingConsentExpiry(String)
  case untrustedConsentIssuer(expected: String, actual: String)
  case invalidConsentSignature(String)
  case reusedConsentReceipt(String)
  case notYetValidConsentReceipt(String)
  case consentVerifierUnavailable(CoreAgentAppleExecutionCapability)
  case invalidAppIntentDescriptor(CoreAgentAppIntentDescriptorError)
  case unexpectedAppIntentDescriptorError(String)
  case unsupportedAppIntentMode(identifier: String, mode: CoreAgentAppleAppIntentMode)
  case unsupportedAppIntentExecutionTarget(
    identifier: String,
    target: CoreAgentAppleAppIntentExecutionTarget
  )
  case appIntentDonationDisabled(identifier: String)
  case appIntentDonationAuthorityBoundaryMismatch(expected: String, actual: String)
  case appIntentDonationPolicyVersionMismatch(expected: Int, actual: Int)
  case appIntentExecutionTargetRequiresForeground(
    identifier: String,
    target: CoreAgentAppleAppIntentExecutionTarget
  )
}

public enum CoreAgentAppleActionGateDecision: Equatable, Sendable {
  case allowed
  case denied(CoreAgentAppleActionGateDenial)

  public var isAllowed: Bool {
    if case .allowed = self { return true }
    return false
  }
}

public struct CoreAgentAppleActionGate: Sendable {
  public let sandbox: CoreAgentAppleSandboxProfile
  public let trustedConsentIssuerID: String
  private let consentSigningKey: CoreAgentAppleConsentSigningKey?
  private let consumedConsentReceipts: CoreAgentAppleConsumedConsentReceipts
  private let now: @Sendable () -> Date

  public init(
    sandbox: CoreAgentAppleSandboxProfile,
    trustedConsentIssuerID: String = "default",
    consentSigningKey: CoreAgentAppleConsentSigningKey? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.sandbox = sandbox
    self.trustedConsentIssuerID = trustedConsentIssuerID
    self.consentSigningKey = consentSigningKey
    self.consumedConsentReceipts = CoreAgentAppleConsumedConsentReceipts()
    self.now = now
  }

  public func consentRequirement(
    for request: CoreAgentAppleExecutionRequest
  ) -> CoreAgentAppleConsentRequirement {
    let policy = policy(for: request)
    return CoreAgentAppleConsentRequirement(
      authorityBoundaryID: sandbox.authorityBoundaryID,
      policyVersion: sandbox.policyVersion,
      capability: policy.requiredCapability,
      requestFingerprint: policy.requestFingerprint
    )
  }

  public func evaluate(
    _ request: CoreAgentAppleExecutionRequest,
    consent: CoreAgentAppleConsent
  ) -> CoreAgentAppleActionGateDecision {
    let policy = policy(for: request)

    if let denial = policy.preflightDenial {
      return .denied(denial)
    }
    guard sandbox.allows(policy.requiredCapability) else {
      return .denied(.missingCapability(policy.requiredCapability))
    }
    guard !policy.consentRequired else {
      let requirement = CoreAgentAppleConsentRequirement(
        authorityBoundaryID: sandbox.authorityBoundaryID,
        policyVersion: sandbox.policyVersion,
        capability: policy.requiredCapability,
        requestFingerprint: policy.requestFingerprint
      )
      if let denial = validate(consent: consent, requirement: requirement) {
        return .denied(denial)
      }
      return .allowed
    }
    return .allowed
  }

  private struct RequestPolicy {
    let requiredCapability: CoreAgentAppleExecutionCapability
    let consentRequired: Bool
    let requestFingerprint: String
    let preflightDenial: CoreAgentAppleActionGateDenial?
  }

  private func policy(for request: CoreAgentAppleExecutionRequest) -> RequestPolicy {
    switch request {
    case .codeInterpreter(let tier):
      if tier == .remote && sandbox.networkPolicy != .allowed {
        return RequestPolicy(
          requiredCapability: tier.requiredCapability,
          consentRequired: true,
          requestFingerprint: fingerprint(["code", tier.rawValue]),
          preflightDenial: .remoteExecutionRequiresNetworkPolicy
        )
      }
      return RequestPolicy(
        requiredCapability: tier.requiredCapability,
        consentRequired: tier == .helperProcess || tier == .remote,
        requestFingerprint: fingerprint(["code", tier.rawValue]),
        preflightDenial: nil
      )
    case .codeInterpreterInvocation(let tier, let programDigest, let inputDigest):
      if tier == .remote && sandbox.networkPolicy != .allowed {
        return RequestPolicy(
          requiredCapability: tier.requiredCapability,
          consentRequired: true,
          requestFingerprint: fingerprint([
            "code-invocation",
            tier.rawValue,
            programDigest,
            inputDigest,
          ]),
          preflightDenial: .remoteExecutionRequiresNetworkPolicy
        )
      }
      return RequestPolicy(
        requiredCapability: tier.requiredCapability,
        consentRequired: tier == .helperProcess || tier == .remote,
        requestFingerprint: fingerprint([
          "code-invocation",
          tier.rawValue,
          programDigest,
          inputDigest,
        ]),
        preflightDenial: nil
      )
    case .computerUsePlan(let actionID):
      return RequestPolicy(
        requiredCapability: .computerUse,
        consentRequired: false,
        requestFingerprint: fingerprint(["computer-use-plan", actionID]),
        preflightDenial: nil
      )
    case .computerUse(let actionID):
      return RequestPolicy(
        requiredCapability: .computerUse,
        consentRequired: true,
        requestFingerprint: fingerprint(["computer-use", actionID]),
        preflightDenial: nil
      )
    case .computerUseExecution(let actionID, let approvedPlanDigest):
      return RequestPolicy(
        requiredCapability: .computerUse,
        consentRequired: true,
        requestFingerprint: fingerprint(["computer-use-execution", actionID, approvedPlanDigest]),
        preflightDenial: nil
      )
    case .swiftDataCheckpointPersistence(let checkpointKey):
      return RequestPolicy(
        requiredCapability: .swiftDataCheckpointPersistence,
        consentRequired: false,
        requestFingerprint: fingerprint(["swiftdata-checkpoint", checkpointKey]),
        preflightDenial: nil
      )
    case .appIntentDonation(let descriptor):
      if let denial = appIntentDonationDenial(descriptor: descriptor) {
        return RequestPolicy(
          requiredCapability: .appIntentDonation,
          consentRequired: true,
          requestFingerprint: fingerprint(["app-intent-donation", descriptor.exposureFingerprint]),
          preflightDenial: denial
        )
      }
      return RequestPolicy(
        requiredCapability: .appIntentDonation,
        consentRequired: true,
        requestFingerprint: fingerprint(["app-intent-donation", descriptor.exposureFingerprint]),
        preflightDenial: nil
      )
    case .appIntentDonationRecord(let record):
      if let denial = appIntentDonationRecordDenial(record: record) {
        return RequestPolicy(
          requiredCapability: .appIntentDonation,
          consentRequired: true,
          requestFingerprint: fingerprint(["app-intent-donation-record", record.gateFingerprint]),
          preflightDenial: denial
        )
      }
      return RequestPolicy(
        requiredCapability: .appIntentDonation,
        consentRequired: true,
        requestFingerprint: fingerprint(["app-intent-donation-record", record.gateFingerprint]),
        preflightDenial: nil
      )
    case .appIntentDonationInvalidation(let record, let reason):
      if let denial = appIntentDonationRecordDenial(record: record) {
        return RequestPolicy(
          requiredCapability: .appIntentDonation,
          consentRequired: true,
          requestFingerprint: fingerprint([
            "app-intent-donation-invalidation",
            record.gateFingerprint,
            reason.rawValue,
          ]),
          preflightDenial: denial
        )
      }
      return RequestPolicy(
        requiredCapability: .appIntentDonation,
        consentRequired: true,
        requestFingerprint: fingerprint([
          "app-intent-donation-invalidation",
          record.gateFingerprint,
          reason.rawValue,
        ]),
        preflightDenial: nil
      )
    case .appIntent(let descriptor, let mode, let target):
      if let denial = appIntentDenial(descriptor: descriptor, mode: mode, target: target) {
        return RequestPolicy(
          requiredCapability: .appIntentExecution,
          consentRequired: true,
          requestFingerprint: fingerprint([
            "app-intent-execution",
            descriptor.exposureFingerprint,
            mode.rawValue,
            target.rawValue,
          ]),
          preflightDenial: denial
        )
      }
      return RequestPolicy(
        requiredCapability: .appIntentExecution,
        consentRequired: true,
        requestFingerprint: fingerprint([
          "app-intent-execution",
          descriptor.exposureFingerprint,
          mode.rawValue,
          target.rawValue,
        ]),
        preflightDenial: nil
      )
    }
  }

  private func appIntentDonationDenial(
    descriptor: CoreAgentAppIntentDescriptor
  ) -> CoreAgentAppleActionGateDenial? {
    do {
      _ = try descriptor.validatedForAgentExposure()
    } catch let error as CoreAgentAppIntentDescriptorError {
      return .invalidAppIntentDescriptor(error)
    } catch {
      return .unexpectedAppIntentDescriptorError(String(describing: error))
    }
    guard descriptor.donationPolicy != .doNotDonate else {
      return .appIntentDonationDisabled(identifier: descriptor.identifier)
    }
    return nil
  }

  private func appIntentDonationRecordDenial(
    record: CoreAgentAppIntentDonationRecord
  ) -> CoreAgentAppleActionGateDenial? {
    guard record.authorityBoundaryID == sandbox.authorityBoundaryID else {
      return .appIntentDonationAuthorityBoundaryMismatch(
        expected: sandbox.authorityBoundaryID,
        actual: record.authorityBoundaryID
      )
    }
    guard record.policyVersion == sandbox.policyVersion else {
      return .appIntentDonationPolicyVersionMismatch(
        expected: sandbox.policyVersion,
        actual: record.policyVersion
      )
    }
    return nil
  }

  private func appIntentDenial(
    descriptor: CoreAgentAppIntentDescriptor,
    mode: CoreAgentAppleAppIntentMode,
    target: CoreAgentAppleAppIntentExecutionTarget
  ) -> CoreAgentAppleActionGateDenial? {
    do {
      _ = try descriptor.validatedForAgentExposure()
    } catch let error as CoreAgentAppIntentDescriptorError {
      return .invalidAppIntentDescriptor(error)
    } catch {
      return .unexpectedAppIntentDescriptorError(String(describing: error))
    }
    guard descriptor.supportedModes.contains(mode) else {
      return .unsupportedAppIntentMode(identifier: descriptor.identifier, mode: mode)
    }
    guard descriptor.allowedExecutionTargets.contains(target) else {
      return .unsupportedAppIntentExecutionTarget(
        identifier: descriptor.identifier,
        target: target
      )
    }
    guard descriptor.mutability == .readOnly || target == .foreground else {
      return .appIntentExecutionTargetRequiresForeground(
        identifier: descriptor.identifier,
        target: target
      )
    }
    return nil
  }

  private func validate(
    consent: CoreAgentAppleConsent,
    requirement: CoreAgentAppleConsentRequirement
  ) -> CoreAgentAppleActionGateDenial? {
    guard case .granted(let receipt) = consent else {
      return .missingConsent(requirement.capability)
    }
    guard !receipt.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .invalidConsentReceipt("empty receipt id")
    }
    guard receipt.authorityBoundaryID == requirement.authorityBoundaryID else {
      return .consentAuthorityBoundaryMismatch(
        expected: requirement.authorityBoundaryID,
        actual: receipt.authorityBoundaryID
      )
    }
    guard receipt.policyVersion == requirement.policyVersion else {
      return .consentPolicyVersionMismatch(
        expected: requirement.policyVersion,
        actual: receipt.policyVersion
      )
    }
    guard receipt.capability == requirement.capability else {
      return .consentCapabilityMismatch(
        expected: requirement.capability,
        actual: receipt.capability
      )
    }
    guard receipt.requestFingerprint == requirement.requestFingerprint else {
      return .consentRequestMismatch(
        expected: requirement.requestFingerprint,
        actual: receipt.requestFingerprint
      )
    }
    guard let expiresAt = receipt.expiresAt else {
      return .missingConsentExpiry(receipt.id)
    }
    let currentTime = now()
    if receipt.grantedAt > currentTime {
      return .notYetValidConsentReceipt(receipt.id)
    }
    if expiresAt <= currentTime {
      return .expiredConsentReceipt(receipt.id)
    }
    guard receipt.issuerID == trustedConsentIssuerID else {
      return .untrustedConsentIssuer(expected: trustedConsentIssuerID, actual: receipt.issuerID)
    }
    guard let consentSigningKey else {
      return .consentVerifierUnavailable(requirement.capability)
    }
    guard receipt.verifies(with: consentSigningKey) else {
      return .invalidConsentSignature(receipt.id)
    }
    guard consumedConsentReceipts.consume(consumptionKey(receipt)) else {
      return .reusedConsentReceipt(receipt.id)
    }
    return nil
  }

  private func fingerprint(_ fields: [String]) -> String {
    fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
  }

  private func consumptionKey(_ receipt: CoreAgentAppleConsentReceipt) -> String {
    fingerprint([
      receipt.id,
      receipt.authorityBoundaryID,
      String(receipt.policyVersion),
      receipt.capability.rawValue,
      receipt.requestFingerprint,
    ])
  }
}

private func stableTimeToken(_ date: Date) -> String {
  let scaled = (date.timeIntervalSinceReferenceDate * 1_000_000_000).rounded()
  guard scaled.isFinite else {
    return scaled.sign == .minus ? String(Int64.min) : String(Int64.max)
  }
  if scaled >= Double(Int64.max) {
    return String(Int64.max)
  }
  if scaled <= Double(Int64.min) {
    return String(Int64.min)
  }
  return String(Int64(scaled))
}
