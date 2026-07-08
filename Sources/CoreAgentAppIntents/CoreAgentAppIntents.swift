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
  public typealias Operation = @Sendable (CoreAgentAppIntentBridgeRequest) async throws ->
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

public struct CoreAgentAppIntentOSDonationToken:
  Codable, Equatable, Hashable, Sendable
{
  public let encodedIdentifier: Data
  public let digest: String

  public init(encodedIdentifier: Data) {
    self.encodedIdentifier = encodedIdentifier
    self.digest = "sha256:" + sha256Hex(encodedIdentifier)
  }

  fileprivate init(identifier: IntentDonationIdentifier) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    self.init(encodedIdentifier: try encoder.encode(identifier))
  }

  fileprivate func osIdentifier() throws -> IntentDonationIdentifier {
    try JSONDecoder().decode(IntentDonationIdentifier.self, from: encodedIdentifier)
  }
}

public struct CoreAgentRunAppIntentDonationBackendAuthorization:
  Codable, Equatable, Hashable, Sendable
{
  public let donationIdentifier: String
  public let descriptorIdentifier: String
  public let subjectKind: CoreAgentAppIntentDonationSubjectKind
  public let subjectStableIdentifier: String
  public let subjectScopeID: String
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let runID: String

  init(record: CoreAgentAppIntentDonationRecord, runID: String) {
    self.donationIdentifier = record.donationIdentifier
    self.descriptorIdentifier = record.descriptorIdentifier
    self.subjectKind = record.subject.kind
    self.subjectStableIdentifier = record.subject.stableIdentifier
    self.subjectScopeID = record.subject.scopeID
    self.authorityBoundaryID = record.authorityBoundaryID
    self.policyVersion = record.policyVersion
    self.runID = runID
  }

  fileprivate func authorizes(
    record: CoreAgentAppIntentDonationRecord,
    runID: String
  ) -> Bool {
    donationIdentifier == record.donationIdentifier
      && descriptorIdentifier == record.descriptorIdentifier
      && subjectKind == record.subject.kind
      && subjectStableIdentifier == record.subject.stableIdentifier
      && subjectScopeID == record.subject.scopeID
      && authorityBoundaryID == record.authorityBoundaryID
      && policyVersion == record.policyVersion
      && self.runID == runID
  }
}

public struct CoreAgentRunAppIntentDonationBackendRequest:
  Codable, Equatable, Sendable
{
  public let kind: CoreAgentRunAppIntentKind
  public let runID: String
  public let record: CoreAgentAppIntentDonationRecord
  public let authorization: CoreAgentRunAppIntentDonationBackendAuthorization

  init(
    kind: CoreAgentRunAppIntentKind,
    runID: String,
    record: CoreAgentAppIntentDonationRecord,
    authorization: CoreAgentRunAppIntentDonationBackendAuthorization
  ) {
    self.kind = kind
    self.runID = runID
    self.record = record
    self.authorization = authorization
  }
}

public enum CoreAgentRunAppIntentDonationBackendError:
  Error, Equatable, Sendable
{
  case invalidRunID(CoreAgentRunAppIntentKind)
  case disabledDonation(identifier: String)
  case descriptorMismatch(expected: String, actual: String)
  case subjectRunIDMismatch(expectedStableIdentifier: String, actualStableIdentifier: String)
  case unauthorizedRequest
}

public protocol CoreAgentRunAppIntentDonationBackend: Sendable {
  func donate(
    _ request: CoreAgentRunAppIntentDonationBackendRequest
  ) async throws -> CoreAgentAppIntentOSDonationToken

  func deleteDonation(
    _ token: CoreAgentAppIntentOSDonationToken
  ) async throws -> [CoreAgentAppIntentOSDonationToken]
}

public struct CoreAgentIntentDonationManagerRunBackend:
  CoreAgentRunAppIntentDonationBackend
{
  public init() {}

  public func validate(
    _ request: CoreAgentRunAppIntentDonationBackendRequest
  ) throws -> CoreAgentAppIntentDescriptor {
    guard CoreAgentRunAppIntentRuntime.isValidRunID(request.runID) else {
      throw CoreAgentRunAppIntentDonationBackendError.invalidRunID(request.kind)
    }
    let descriptor = try Self.descriptor(for: request.kind).validatedForAgentExposure()
    guard descriptor.donationPolicy != .doNotDonate else {
      throw CoreAgentRunAppIntentDonationBackendError.disabledDonation(
        identifier: descriptor.identifier
      )
    }
    guard request.record.descriptorIdentifier == descriptor.identifier else {
      throw CoreAgentRunAppIntentDonationBackendError.descriptorMismatch(
        expected: descriptor.identifier,
        actual: request.record.descriptorIdentifier
      )
    }
    guard request.authorization.authorizes(record: request.record, runID: request.runID) else {
      throw CoreAgentRunAppIntentDonationBackendError.unauthorizedRequest
    }
    if let expected = Self.expectedRunOutcomeStableIdentifier(
      kind: request.kind,
      runID: request.runID
    ) {
      guard request.record.subject.kind == .runOutcome
        && request.record.subject.stableIdentifier == expected
      else {
        throw CoreAgentRunAppIntentDonationBackendError.subjectRunIDMismatch(
          expectedStableIdentifier: expected,
          actualStableIdentifier: request.record.subject.stableIdentifier
        )
      }
    }
    return descriptor
  }

  public func donate(
    _ request: CoreAgentRunAppIntentDonationBackendRequest
  ) async throws -> CoreAgentAppIntentOSDonationToken {
    _ = try validate(request)
    let identifier: IntentDonationIdentifier
    switch request.kind {
    case .openRun:
      identifier = try await IntentDonationManager.shared.donate(
        intent: CoreAgentOpenRunIntent(runID: request.runID)
      )
    case .pauseRun:
      identifier = try await IntentDonationManager.shared.donate(
        intent: CoreAgentPauseRunIntent(runID: request.runID)
      )
    case .continueRun:
      identifier = try await IntentDonationManager.shared.donate(
        intent: CoreAgentContinueRunIntent(runID: request.runID)
      )
    }
    return try CoreAgentAppIntentOSDonationToken(identifier: identifier)
  }

  public func deleteDonation(
    _ token: CoreAgentAppIntentOSDonationToken
  ) async throws -> [CoreAgentAppIntentOSDonationToken] {
    let identifier = try token.osIdentifier()
    let deleted = try await IntentDonationManager.shared.deleteDonations(
      matching: .donationIdentifier(identifier)
    )
    return try deleted.map(CoreAgentAppIntentOSDonationToken.init(identifier:))
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

  private static func expectedRunOutcomeStableIdentifier(
    kind: CoreAgentRunAppIntentKind,
    runID: String
  ) -> String? {
    switch kind {
    case .openRun:
      nil
    case .pauseRun:
      "\(runID):paused"
    case .continueRun:
      "\(runID):continued"
    }
  }
}

public struct CoreAgentRunAppIntentDonationRequest: Equatable, Sendable {
  public let kind: CoreAgentRunAppIntentKind
  public let runID: String
  public let subject: CoreAgentAppIntentDonationSubject
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let consent: CoreAgentAppleConsent

  public init(
    kind: CoreAgentRunAppIntentKind,
    runID: String,
    subject: CoreAgentAppIntentDonationSubject,
    authorityBoundaryID: String,
    policyVersion: Int,
    consent: CoreAgentAppleConsent
  ) {
    self.kind = kind
    self.runID = runID
    self.subject = subject
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.consent = consent
  }
}

public enum CoreAgentRunAppIntentDonationRejection: Equatable, Sendable {
  case invalidRunID(CoreAgentRunAppIntentKind)
  case invalidDonationRecord(CoreAgentAppIntentDonationError)
  case subjectRunIDMismatch(expectedStableIdentifier: String, actualStableIdentifier: String)
  case unexpectedDonationRecordError(String)
  case localRecordRejected(String)
}

public struct CoreAgentRunAppIntentDonationReceipt:
  Codable, Equatable, Identifiable, Sendable
{
  public var id: String { record.donationIdentifier }

  public let record: CoreAgentAppIntentDonationRecord
  public let osDonationToken: CoreAgentAppIntentOSDonationToken
  public let osDonationIdentifierDigest: String
  public let donatedAt: Date

  public init(
    record: CoreAgentAppIntentDonationRecord,
    osDonationToken: CoreAgentAppIntentOSDonationToken,
    osDonationIdentifierDigest: String,
    donatedAt: Date
  ) {
    self.record = record
    self.osDonationToken = osDonationToken
    self.osDonationIdentifierDigest = osDonationToken.digest
    self.donatedAt = donatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case record
    case osDonationToken
    case osDonationIdentifierDigest
    case donatedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let record = try container.decode(CoreAgentAppIntentDonationRecord.self, forKey: .record)
    let token = try container.decode(
      CoreAgentAppIntentOSDonationToken.self,
      forKey: .osDonationToken
    )
    let digest = try container.decode(String.self, forKey: .osDonationIdentifierDigest)
    guard digest == token.digest else {
      throw DecodingError.dataCorruptedError(
        forKey: .osDonationIdentifierDigest,
        in: container,
        debugDescription: "OS donation identifier digest does not match token"
      )
    }
    self.record = record
    self.osDonationToken = token
    self.osDonationIdentifierDigest = digest
    self.donatedAt = try container.decode(Date.self, forKey: .donatedAt)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(record, forKey: .record)
    try container.encode(osDonationToken, forKey: .osDonationToken)
    try container.encode(osDonationIdentifierDigest, forKey: .osDonationIdentifierDigest)
    try container.encode(donatedAt, forKey: .donatedAt)
  }
}

public enum CoreAgentRunAppIntentDonationStatus: Equatable, Sendable {
  case donated(CoreAgentRunAppIntentDonationReceipt)
  case denied(CoreAgentAppleActionGateDenial)
  case rejected(CoreAgentRunAppIntentDonationRejection)
  case failed(String)
}

public struct CoreAgentRunAppIntentDonationResult: Equatable, Sendable {
  public let status: CoreAgentRunAppIntentDonationStatus

  public init(status: CoreAgentRunAppIntentDonationStatus) {
    self.status = status
  }
}

public struct CoreAgentRunAppIntentDonationInvalidationRequest:
  Equatable, Sendable
{
  public let receipt: CoreAgentRunAppIntentDonationReceipt
  public let request: CoreAgentAppIntentDonationInvalidationRequest
  public let consent: CoreAgentAppleConsent

  public init(
    receipt: CoreAgentRunAppIntentDonationReceipt,
    request: CoreAgentAppIntentDonationInvalidationRequest,
    consent: CoreAgentAppleConsent
  ) {
    self.receipt = receipt
    self.request = request
    self.consent = consent
  }
}

public enum CoreAgentRunAppIntentDonationInvalidationStatus:
  Equatable, Sendable
{
  case invalidated
  case denied(CoreAgentAppleActionGateDenial)
  case skipped
  case failed(String)
}

public struct CoreAgentRunAppIntentDonationInvalidationResult:
  Equatable, Sendable
{
  public let receipt: CoreAgentRunAppIntentDonationReceipt
  public let deletedOSDonationIdentifierDigests: [String]
  public let invalidationRecords: [CoreAgentAppIntentDonationInvalidationRecord]
  public let status: CoreAgentRunAppIntentDonationInvalidationStatus

  public init(
    receipt: CoreAgentRunAppIntentDonationReceipt,
    deletedOSDonationIdentifierDigests: [String],
    invalidationRecords: [CoreAgentAppIntentDonationInvalidationRecord],
    status: CoreAgentRunAppIntentDonationInvalidationStatus
  ) {
    self.receipt = receipt
    self.deletedOSDonationIdentifierDigests = deletedOSDonationIdentifierDigests
    self.invalidationRecords = invalidationRecords
    self.status = status
  }
}

public struct CoreAgentRunAppIntentDonationBridge: Sendable {
  public let actionGate: CoreAgentAppleActionGate
  private let backend: any CoreAgentRunAppIntentDonationBackend
  private let store: InMemoryCoreAgentAppIntentDonationStore?
  private let now: @Sendable () -> Date

  public init(
    actionGate: CoreAgentAppleActionGate,
    backend: any CoreAgentRunAppIntentDonationBackend =
      CoreAgentIntentDonationManagerRunBackend(),
    store: InMemoryCoreAgentAppIntentDonationStore? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.actionGate = actionGate
    self.backend = backend
    self.store = store
    self.now = now
  }

  public func donate(
    _ request: CoreAgentRunAppIntentDonationRequest
  ) async -> CoreAgentRunAppIntentDonationResult {
    guard CoreAgentRunAppIntentRuntime.isValidRunID(request.runID) else {
      return CoreAgentRunAppIntentDonationResult(status: .rejected(.invalidRunID(request.kind)))
    }
    let donationTime = now()
    let record: CoreAgentAppIntentDonationRecord
    do {
      record = try CoreAgentAppIntentDonationRecord(
        descriptor: Self.descriptor(for: request.kind),
        subject: request.subject,
        authorityBoundaryID: request.authorityBoundaryID,
        policyVersion: request.policyVersion,
        donatedAt: donationTime
      )
    } catch let error as CoreAgentAppIntentDonationError {
      return CoreAgentRunAppIntentDonationResult(
        status: .rejected(.invalidDonationRecord(error))
      )
    } catch {
      return CoreAgentRunAppIntentDonationResult(
        status: .rejected(.unexpectedDonationRecordError(String(describing: error)))
      )
    }
    if let expected = Self.expectedRunOutcomeStableIdentifier(
      kind: request.kind,
      runID: request.runID
    ) {
      guard record.subject.kind == .runOutcome
        && record.subject.stableIdentifier == expected
      else {
        return CoreAgentRunAppIntentDonationResult(
          status: .rejected(.subjectRunIDMismatch(
            expectedStableIdentifier: expected,
            actualStableIdentifier: record.subject.stableIdentifier
          ))
        )
      }
    }

    let executionRequest = CoreAgentAppleExecutionRequest.appIntentDonationRecord(record: record)
    switch actionGate.evaluate(executionRequest, consent: request.consent) {
    case .allowed:
      break
    case .denied(let denial):
      return CoreAgentRunAppIntentDonationResult(status: .denied(denial))
    }

    if let store {
      let recorded = await store.record(record)
      guard recorded else {
        return CoreAgentRunAppIntentDonationResult(
          status: .rejected(.localRecordRejected(record.donationIdentifier))
        )
      }
    }

    do {
      let token = try await backend.donate(
        CoreAgentRunAppIntentDonationBackendRequest(
          kind: request.kind,
          runID: request.runID,
          record: record,
          authorization: CoreAgentRunAppIntentDonationBackendAuthorization(
            record: record,
            runID: request.runID
          )
        )
      )
      return CoreAgentRunAppIntentDonationResult(
        status: .donated(CoreAgentRunAppIntentDonationReceipt(
          record: record,
          osDonationToken: token,
          osDonationIdentifierDigest: token.digest,
          donatedAt: donationTime
        ))
      )
    } catch {
      if let store {
        _ = await store.invalidate(CoreAgentAppIntentDonationInvalidationRequest(
          donationIdentifier: record.donationIdentifier,
          reason: .systemDonationFailed,
          invalidatedAt: now()
        ))
      }
      return CoreAgentRunAppIntentDonationResult(status: .failed(String(describing: error)))
    }
  }

  public func invalidate(
    _ request: CoreAgentRunAppIntentDonationInvalidationRequest
  ) async -> CoreAgentRunAppIntentDonationInvalidationResult {
    guard Self.invalidationRequest(request.request, matches: request.receipt.record) else {
      return CoreAgentRunAppIntentDonationInvalidationResult(
        receipt: request.receipt,
        deletedOSDonationIdentifierDigests: [],
        invalidationRecords: [],
        status: .skipped
      )
    }
    switch actionGate.evaluate(
      .appIntentDonationInvalidation(
        record: request.receipt.record,
        reason: request.request.reason
      ),
      consent: request.consent
    ) {
    case .allowed:
      break
    case .denied(let denial):
      return CoreAgentRunAppIntentDonationInvalidationResult(
        receipt: request.receipt,
        deletedOSDonationIdentifierDigests: [],
        invalidationRecords: [],
        status: .denied(denial)
      )
    }
    do {
      let deleted = try await backend.deleteDonation(request.receipt.osDonationToken)
      let invalidationRecords: [CoreAgentAppIntentDonationInvalidationRecord]
      if let store {
        invalidationRecords = await store.invalidate(request.request)
      } else {
        invalidationRecords = [
          CoreAgentAppIntentDonationInvalidationRecord(
            donationIdentifier: request.receipt.record.donationIdentifier,
            descriptorIdentifier: request.receipt.record.descriptorIdentifier,
            subject: request.receipt.record.subject,
            reason: request.request.reason,
            invalidatedAt: request.request.invalidatedAt
          )
        ]
      }
      return CoreAgentRunAppIntentDonationInvalidationResult(
        receipt: request.receipt,
        deletedOSDonationIdentifierDigests: deleted.map(\.digest).sorted(),
        invalidationRecords: invalidationRecords,
        status: .invalidated
      )
    } catch {
      return CoreAgentRunAppIntentDonationInvalidationResult(
        receipt: request.receipt,
        deletedOSDonationIdentifierDigests: [],
        invalidationRecords: [],
        status: .failed(String(describing: error))
      )
    }
  }

  private static func invalidationRequest(
    _ request: CoreAgentAppIntentDonationInvalidationRequest,
    matches record: CoreAgentAppIntentDonationRecord
  ) -> Bool {
    guard request.donationIdentifier != nil || request.scopeID != nil else {
      return false
    }
    let matchesDonation = request.donationIdentifier.map {
      $0 == record.donationIdentifier
    } ?? true
    let matchesScope = request.scopeID.map {
      $0 == record.subject.scopeID
    } ?? true
    return matchesDonation && matchesScope
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

  private static func expectedRunOutcomeStableIdentifier(
    kind: CoreAgentRunAppIntentKind,
    runID: String
  ) -> String? {
    switch kind {
    case .openRun:
      nil
    case .pauseRun:
      "\(runID):paused"
    case .continueRun:
      "\(runID):continued"
    }
  }
}

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
  public typealias ModeProvider = @Sendable (CoreAgentRunAppIntentRuntimeRequest)
    -> CoreAgentAppleAppIntentMode
  public typealias TargetProvider = @Sendable (CoreAgentRunAppIntentRuntimeRequest)
    -> CoreAgentAppleAppIntentExecutionTarget
  public typealias ConsentProvider = @Sendable (CoreAgentRunAppIntentRuntimeRequest)
    -> CoreAgentAppleConsent
  public typealias CheckpointKeyProvider = @Sendable (CoreAgentRunAppIntentRuntimeRequest)
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

  fileprivate static func isValidRunID(_ runID: String) -> Bool {
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

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
