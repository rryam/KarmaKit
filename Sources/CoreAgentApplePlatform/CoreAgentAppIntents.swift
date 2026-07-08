import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CryptoKit
import Foundation
import Observation
import SwiftData

public enum CoreAgentAppIntentMutability: String, Codable, Equatable, Sendable {
  case readOnly
  case mutating
  case destructive
}

public enum CoreAgentAppleAppIntentExecutionTarget: String, Codable, Hashable, Sendable {
  case foreground
  case background
}

public enum CoreAgentAppleAppIntentMode: String, Codable, Hashable, Sendable {
  case app
  case siri
  case shortcuts
  case spotlight
}

public enum CoreAgentAppIntentDonationPolicy: String, Codable, Equatable, Sendable {
  case doNotDonate
  case donateAfterUserInitiatedAction
}

public enum CoreAgentAppIntentDescriptorError: Error, Equatable, Sendable {
  case missingExecutionTarget(identifier: String)
  case missingSupportedMode(identifier: String)
  case agentExposureRequired(identifier: String)
  case authorizationRequired(identifier: String)
  case hitlRequired(identifier: String)
  case foregroundExecutionRequired(identifier: String)
}

public struct CoreAgentAppIntentDescriptor: Equatable, Sendable {
  public let identifier: String
  public let title: String
  public let mutability: CoreAgentAppIntentMutability
  public let exposureRevision: String
  public let allowsAgentExecution: Bool
  public let allowedExecutionTargets: Set<CoreAgentAppleAppIntentExecutionTarget>
  public let supportedModes: Set<CoreAgentAppleAppIntentMode>
  public let donationPolicy: CoreAgentAppIntentDonationPolicy
  public let requiresAuthorization: Bool
  public let requiresHITLForSensitiveOperations: Bool

  public init(
    identifier: String,
    title: String,
    mutability: CoreAgentAppIntentMutability,
    exposureRevision: String = "1",
    allowsAgentExecution: Bool,
    allowedExecutionTargets: Set<CoreAgentAppleAppIntentExecutionTarget>,
    supportedModes: Set<CoreAgentAppleAppIntentMode>,
    donationPolicy: CoreAgentAppIntentDonationPolicy,
    requiresAuthorization: Bool,
    requiresHITLForSensitiveOperations: Bool
  ) {
    self.identifier = identifier
    self.title = title
    self.mutability = mutability
    self.exposureRevision = exposureRevision
    self.allowsAgentExecution = allowsAgentExecution
    self.allowedExecutionTargets = allowedExecutionTargets
    self.supportedModes = supportedModes
    self.donationPolicy = donationPolicy
    self.requiresAuthorization = requiresAuthorization
    self.requiresHITLForSensitiveOperations = requiresHITLForSensitiveOperations
  }

  public func validatedForAgentExposure() throws -> Self {
    guard !allowedExecutionTargets.isEmpty else {
      throw CoreAgentAppIntentDescriptorError.missingExecutionTarget(identifier: identifier)
    }
    guard !supportedModes.isEmpty else {
      throw CoreAgentAppIntentDescriptorError.missingSupportedMode(identifier: identifier)
    }
    guard allowsAgentExecution else {
      throw CoreAgentAppIntentDescriptorError.agentExposureRequired(identifier: identifier)
    }
    guard mutability == .readOnly || requiresAuthorization else {
      throw CoreAgentAppIntentDescriptorError.authorizationRequired(identifier: identifier)
    }
    guard mutability == .readOnly || requiresHITLForSensitiveOperations else {
      throw CoreAgentAppIntentDescriptorError.hitlRequired(identifier: identifier)
    }
    guard mutability == .readOnly || allowedExecutionTargets.contains(.foreground) else {
      throw CoreAgentAppIntentDescriptorError.foregroundExecutionRequired(identifier: identifier)
    }
    return self
  }

  public var exposureFingerprint: String {
    Self.fingerprint([
      identifier,
      title,
      mutability.rawValue,
      exposureRevision,
      allowsAgentExecution ? "agent-exposed" : "not-agent-exposed",
      allowedExecutionTargets.map(\.rawValue).sorted().joined(separator: ","),
      supportedModes.map(\.rawValue).sorted().joined(separator: ","),
      donationPolicy.rawValue,
      requiresAuthorization ? "requires-authorization" : "no-authorization",
      requiresHITLForSensitiveOperations ? "requires-hitl" : "no-hitl",
    ])
  }

  private static func fingerprint(_ fields: [String]) -> String {
    fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
  }
}

public enum CoreAgentAppIntentDonationSubjectKind:
  String, Codable, Equatable, Hashable, Sendable
{
  case workflowOutcome
  case stableEntity
  case runOutcome
  case traceIssue
  case memoryRecord
  case promptText
  case toolArguments
  case transientToolCall

  var isDonationAllowed: Bool {
    switch self {
    case .workflowOutcome, .stableEntity, .runOutcome, .traceIssue, .memoryRecord:
      true
    case .promptText, .toolArguments, .transientToolCall:
      false
    }
  }
}

public struct CoreAgentAppIntentDonationSubject:
  Codable, Equatable, Hashable, Sendable
{
  public let kind: CoreAgentAppIntentDonationSubjectKind
  public let stableIdentifier: String
  public let scopeID: String

  public init(
    kind: CoreAgentAppIntentDonationSubjectKind,
    stableIdentifier: String,
    scopeID: String
  ) {
    self.kind = kind
    self.stableIdentifier = stableIdentifier
    self.scopeID = scopeID
  }

  func validatedForDonation() throws -> Self {
    guard kind.isDonationAllowed else {
      throw CoreAgentAppIntentDonationError.disallowedSubjectKind(kind)
    }
    guard !stableIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentAppIntentDonationError.emptyStableIdentifier
    }
    guard !scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentAppIntentDonationError.emptyScopeID
    }
    return self
  }
}

public enum CoreAgentAppIntentDonationError: Error, Equatable, Sendable {
  case disallowedSubjectKind(CoreAgentAppIntentDonationSubjectKind)
  case emptyStableIdentifier
  case emptyScopeID
  case disabledDonation(identifier: String)
  case invalidDescriptor(CoreAgentAppIntentDescriptorError)
  case unexpectedDescriptorError(String)
  case donationIdentifierMismatch(expected: String, actual: String)
}

public struct CoreAgentAppIntentDonationRecord:
  Codable, Equatable, Identifiable, Sendable
{
  public var id: String { donationIdentifier }

  public let donationIdentifier: String
  public let descriptorIdentifier: String
  public let descriptorExposureFingerprint: String
  public let subject: CoreAgentAppIntentDonationSubject
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let donatedAt: Date

  enum CodingKeys: String, CodingKey {
    case donationIdentifier
    case descriptorIdentifier
    case descriptorExposureFingerprint
    case subject
    case authorityBoundaryID
    case policyVersion
    case donatedAt
  }

  public init(
    descriptor: CoreAgentAppIntentDescriptor,
    subject: CoreAgentAppIntentDonationSubject,
    authorityBoundaryID: String,
    policyVersion: Int,
    donatedAt: Date = Date()
  ) throws {
    do {
      _ = try descriptor.validatedForAgentExposure()
    } catch let error as CoreAgentAppIntentDescriptorError {
      throw CoreAgentAppIntentDonationError.invalidDescriptor(error)
    } catch {
      throw CoreAgentAppIntentDonationError.unexpectedDescriptorError(String(describing: error))
    }
    guard descriptor.donationPolicy != .doNotDonate else {
      throw CoreAgentAppIntentDonationError.disabledDonation(identifier: descriptor.identifier)
    }
    let validatedSubject = try subject.validatedForDonation()
    self.descriptorIdentifier = descriptor.identifier
    self.descriptorExposureFingerprint = descriptor.exposureFingerprint
    self.subject = validatedSubject
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.donatedAt = donatedAt
    self.donationIdentifier = Self.makeDonationIdentifier(
      descriptorIdentifier: descriptor.identifier,
      descriptorExposureFingerprint: descriptor.exposureFingerprint,
      subject: validatedSubject,
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion
    )
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let donationIdentifier = try container.decode(String.self, forKey: .donationIdentifier)
    let descriptorIdentifier = try container.decode(String.self, forKey: .descriptorIdentifier)
    let descriptorExposureFingerprint = try container.decode(
      String.self,
      forKey: .descriptorExposureFingerprint
    )
    let subject = try container.decode(CoreAgentAppIntentDonationSubject.self, forKey: .subject)
      .validatedForDonation()
    let authorityBoundaryID = try container.decode(String.self, forKey: .authorityBoundaryID)
    let policyVersion = try container.decode(Int.self, forKey: .policyVersion)
    let donatedAt = try container.decode(Date.self, forKey: .donatedAt)
    let expectedIdentifier = Self.makeDonationIdentifier(
      descriptorIdentifier: descriptorIdentifier,
      descriptorExposureFingerprint: descriptorExposureFingerprint,
      subject: subject,
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion
    )
    guard donationIdentifier == expectedIdentifier else {
      throw CoreAgentAppIntentDonationError.donationIdentifierMismatch(
        expected: expectedIdentifier,
        actual: donationIdentifier
      )
    }
    self.donationIdentifier = donationIdentifier
    self.descriptorIdentifier = descriptorIdentifier
    self.descriptorExposureFingerprint = descriptorExposureFingerprint
    self.subject = subject
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.donatedAt = donatedAt
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(donationIdentifier, forKey: .donationIdentifier)
    try container.encode(descriptorIdentifier, forKey: .descriptorIdentifier)
    try container.encode(descriptorExposureFingerprint, forKey: .descriptorExposureFingerprint)
    try container.encode(subject, forKey: .subject)
    try container.encode(authorityBoundaryID, forKey: .authorityBoundaryID)
    try container.encode(policyVersion, forKey: .policyVersion)
    try container.encode(donatedAt, forKey: .donatedAt)
  }

  var gateFingerprint: String {
    "sha256:"
      + sha256Hex(
        framed([
          donationIdentifier,
          descriptorIdentifier,
          descriptorExposureFingerprint,
          subject.kind.rawValue,
          subject.stableIdentifier,
          subject.scopeID,
          authorityBoundaryID,
          String(policyVersion),
        ]))
  }

  private static func makeDonationIdentifier(
    descriptorIdentifier: String,
    descriptorExposureFingerprint: String,
    subject: CoreAgentAppIntentDonationSubject,
    authorityBoundaryID: String,
    policyVersion: Int
  ) -> String {
    "coreagent-app-intent-donation-sha256-v1:"
      + sha256Hex(
        framed([
          descriptorIdentifier,
          descriptorExposureFingerprint,
          subject.kind.rawValue,
          subject.stableIdentifier,
          subject.scopeID,
          authorityBoundaryID,
          String(policyVersion),
        ]))
  }

  private static func fingerprint(_ fields: [String]) -> String {
    fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
  }
}

public enum CoreAgentAppIntentDonationInvalidationReason:
  String, Codable, Equatable, Sendable
{
  case erased
  case accessScopeChanged
  case descriptorChanged
  case policyChanged
  case systemDonationFailed
  case userRevoked
}

public struct CoreAgentAppIntentDonationInvalidationRequest:
  Codable, Equatable, Sendable
{
  public let donationIdentifier: String?
  public let scopeID: String?
  public let reason: CoreAgentAppIntentDonationInvalidationReason
  public let invalidatedAt: Date

  public init(
    donationIdentifier: String? = nil,
    scopeID: String? = nil,
    reason: CoreAgentAppIntentDonationInvalidationReason,
    invalidatedAt: Date = Date()
  ) {
    self.donationIdentifier = donationIdentifier
    self.scopeID = scopeID
    self.reason = reason
    self.invalidatedAt = invalidatedAt
  }
}

public struct CoreAgentAppIntentDonationInvalidationRecord:
  Codable, Equatable, Identifiable, Sendable
{
  public var id: String { donationIdentifier }

  public let donationIdentifier: String
  public let descriptorIdentifier: String
  public let subject: CoreAgentAppIntentDonationSubject
  public let reason: CoreAgentAppIntentDonationInvalidationReason
  public let invalidatedAt: Date

  public init(
    donationIdentifier: String,
    descriptorIdentifier: String,
    subject: CoreAgentAppIntentDonationSubject,
    reason: CoreAgentAppIntentDonationInvalidationReason,
    invalidatedAt: Date
  ) {
    self.donationIdentifier = donationIdentifier
    self.descriptorIdentifier = descriptorIdentifier
    self.subject = subject
    self.reason = reason
    self.invalidatedAt = invalidatedAt
  }
}

public actor InMemoryCoreAgentAppIntentDonationStore {
  private var recordsByIdentifier: [String: CoreAgentAppIntentDonationRecord]
  private var invalidations: [CoreAgentAppIntentDonationInvalidationRecord]
  private var invalidatedDonationIdentifiers: Set<String>
  private var invalidatedScopeIDs: Set<String>

  public init(records: [CoreAgentAppIntentDonationRecord] = []) {
    self.recordsByIdentifier = Dictionary(
      uniqueKeysWithValues: records.map { ($0.donationIdentifier, $0) }
    )
    self.invalidations = []
    self.invalidatedDonationIdentifiers = []
    self.invalidatedScopeIDs = []
  }

  @discardableResult
  public func record(_ record: CoreAgentAppIntentDonationRecord) -> Bool {
    guard !invalidatedDonationIdentifiers.contains(record.donationIdentifier),
      !invalidatedScopeIDs.contains(record.subject.scopeID)
    else {
      return false
    }
    recordsByIdentifier[record.donationIdentifier] = record
    return true
  }

  public func activeRecords() -> [CoreAgentAppIntentDonationRecord] {
    recordsByIdentifier.values.sorted(by: Self.recordSort)
  }

  public func invalidationRecords() -> [CoreAgentAppIntentDonationInvalidationRecord] {
    invalidations
  }

  @discardableResult
  public func invalidate(
    _ request: CoreAgentAppIntentDonationInvalidationRequest
  ) -> [CoreAgentAppIntentDonationInvalidationRecord] {
    guard request.donationIdentifier != nil || request.scopeID != nil else {
      return []
    }
    let matched = activeRecords().filter { record in
      let matchesDonation =
        request.donationIdentifier.map {
          $0 == record.donationIdentifier
        } ?? true
      let matchesScope =
        request.scopeID.map {
          $0 == record.subject.scopeID
        } ?? true
      return matchesDonation && matchesScope
    }
    let invalidated = matched.map { record in
      CoreAgentAppIntentDonationInvalidationRecord(
        donationIdentifier: record.donationIdentifier,
        descriptorIdentifier: record.descriptorIdentifier,
        subject: record.subject,
        reason: request.reason,
        invalidatedAt: request.invalidatedAt
      )
    }
    for record in matched {
      recordsByIdentifier.removeValue(forKey: record.donationIdentifier)
      invalidatedDonationIdentifiers.insert(record.donationIdentifier)
      invalidatedScopeIDs.insert(record.subject.scopeID)
    }
    if let donationIdentifier = request.donationIdentifier {
      invalidatedDonationIdentifiers.insert(donationIdentifier)
    }
    if let scopeID = request.scopeID {
      invalidatedScopeIDs.insert(scopeID)
    }
    invalidations.append(contentsOf: invalidated)
    return invalidated
  }

  private static func recordSort(
    _ lhs: CoreAgentAppIntentDonationRecord,
    _ rhs: CoreAgentAppIntentDonationRecord
  ) -> Bool {
    if lhs.donatedAt != rhs.donatedAt {
      return lhs.donatedAt < rhs.donatedAt
    }
    return lhs.donationIdentifier < rhs.donationIdentifier
  }
}

private func framed(_ fields: [String]) -> Data {
  Data(fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|").utf8)
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
