import CryptoKit
import Foundation

public enum FoundationModelsAgentMemoryError: Error, LocalizedError, Sendable {
  case invalidScopeComponent(String)
  case emptyContent
  case scopeMismatch
  case recordNotFound(UUID)
  case candidateNotFound(UUID)
  case consolidationJobNotFound(UUID)
  case sourceRecordInactive(UUID)
  case invalidCandidateDecision
  case sqlite(String)
  case unsupportedSchemaVersion(Int32)
  case exportFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidScopeComponent(let component):
      "Memory scope requires a nonempty \(component)."
    case .emptyContent:
      "Memory content must not be empty."
    case .scopeMismatch:
      "A memory object cannot move between application, user, or agent scopes."
    case .recordNotFound(let id):
      "Memory record \(id.uuidString.lowercased()) was not found."
    case .candidateNotFound(let id):
      "Memory candidate \(id.uuidString.lowercased()) was not found."
    case .consolidationJobNotFound(let id):
      "Memory consolidation job \(id.uuidString.lowercased()) was not found."
    case .sourceRecordInactive(let id):
      "Memory source record \(id.uuidString.lowercased()) is not active."
    case .invalidCandidateDecision:
      "Only pending memory candidates can be approved or rejected."
    case .sqlite(let message):
      "SQLite memory store failed: \(message)"
    case .unsupportedSchemaVersion(let version):
      "The memory database schema version \(version) is not supported."
    case .exportFailed(let message):
      "Memory export failed: \(message)"
    }
  }
}

public struct FoundationModelsAgentMemoryScope: Codable, Hashable, Sendable {
  public let applicationID: String
  public let userID: String
  public let agentID: String

  public init(applicationID: String, userID: String, agentID: String) throws {
    let applicationID = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
    let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    let agentID = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !applicationID.isEmpty else {
      throw FoundationModelsAgentMemoryError.invalidScopeComponent("application identifier")
    }
    guard !userID.isEmpty else {
      throw FoundationModelsAgentMemoryError.invalidScopeComponent("user identifier")
    }
    guard !agentID.isEmpty else {
      throw FoundationModelsAgentMemoryError.invalidScopeComponent("agent identifier")
    }
    self.applicationID = applicationID
    self.userID = userID
    self.agentID = agentID
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      applicationID: container.decode(String.self, forKey: .applicationID),
      userID: container.decode(String.self, forKey: .userID),
      agentID: container.decode(String.self, forKey: .agentID)
    )
  }
}

public enum FoundationModelsAgentMemoryKind: String, Codable, CaseIterable, Sendable {
  case episode
  case fact
  case preference
  case procedure
  case reflection
}

public enum FoundationModelsAgentMemoryAuthority: String, Codable, CaseIterable, Sendable {
  case assistantInference
  case priorUserStatement
  case trustedApplication
  case trustedTool
  case explicitUserCorrection

  public var rank: Int {
    switch self {
    case .assistantInference: 0
    case .priorUserStatement: 1
    case .trustedApplication, .trustedTool: 2
    case .explicitUserCorrection: 3
    }
  }
}

public enum FoundationModelsAgentMemorySensitivity: String, Codable, CaseIterable, Sendable {
  case general
  case personal
  case restricted
}

public enum FoundationModelsAgentMemoryStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case active
  case superseded
  case tombstoned
}

public enum FoundationModelsAgentMemoryRetention: Codable, Equatable, Sendable {
  case persistent
  case until(Date)
  case episodeOnly
}

public enum FoundationModelsAgentMemoryIndexState: String, Codable, CaseIterable, Sendable {
  case notConfigured
  case pending
  case indexed
  case failed
}

public enum FoundationModelsAgentMemorySourceKind: String, Codable, CaseIterable, Sendable {
  case conversation
  case application
  case tool
  case correction
  case importFile
}

public struct FoundationModelsAgentMemorySource: Codable, Equatable, Sendable {
  public var kind: FoundationModelsAgentMemorySourceKind
  public var runID: UUID?
  public var transcriptEntryIDs: [String]
  public var toolName: String?
  public var assetReferences: [String]
  public var metadata: [String: String]

  public init(
    kind: FoundationModelsAgentMemorySourceKind,
    runID: UUID? = nil,
    transcriptEntryIDs: [String] = [],
    toolName: String? = nil,
    assetReferences: [String] = [],
    metadata: [String: String] = [:]
  ) {
    self.kind = kind
    self.runID = runID
    self.transcriptEntryIDs = transcriptEntryIDs
    self.toolName = toolName
    self.assetReferences = assetReferences
    self.metadata = metadata
  }
}

public struct FoundationModelsAgentMemoryRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var scope: FoundationModelsAgentMemoryScope
  public var kind: FoundationModelsAgentMemoryKind
  public var content: String
  public var source: FoundationModelsAgentMemorySource
  public var observedAt: Date
  public var validFrom: Date?
  public var validUntil: Date?
  public var authority: FoundationModelsAgentMemoryAuthority
  public var confidence: Double
  public var importance: Double
  public var sensitivity: FoundationModelsAgentMemorySensitivity
  public var status: FoundationModelsAgentMemoryStatus
  public var retention: FoundationModelsAgentMemoryRetention
  public var contentHash: String
  public var supersedes: [UUID]
  public var supersededBy: UUID?
  public var indexState: FoundationModelsAgentMemoryIndexState
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    scope: FoundationModelsAgentMemoryScope,
    kind: FoundationModelsAgentMemoryKind,
    content: String,
    source: FoundationModelsAgentMemorySource,
    observedAt: Date = Date(),
    validFrom: Date? = nil,
    validUntil: Date? = nil,
    authority: FoundationModelsAgentMemoryAuthority,
    confidence: Double = 1,
    importance: Double = 0.5,
    sensitivity: FoundationModelsAgentMemorySensitivity = .personal,
    status: FoundationModelsAgentMemoryStatus = .active,
    retention: FoundationModelsAgentMemoryRetention = .persistent,
    contentHash: String? = nil,
    supersedes: [UUID] = [],
    supersededBy: UUID? = nil,
    indexState: FoundationModelsAgentMemoryIndexState = .notConfigured,
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) throws {
    let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { throw FoundationModelsAgentMemoryError.emptyContent }
    self.id = id
    self.scope = scope
    self.kind = kind
    self.content = content
    self.source = source
    self.observedAt = observedAt
    self.validFrom = validFrom
    self.validUntil = validUntil
    self.authority = authority
    self.confidence = min(max(confidence, 0), 1)
    self.importance = min(max(importance, 0), 1)
    self.sensitivity = sensitivity
    self.status = status
    self.retention = retention
    self.contentHash = contentHash ?? Self.hash(content)
    self.supersedes = supersedes
    self.supersededBy = supersededBy
    self.indexState = indexState
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }

  public var isActive: Bool { status == .active }

  public func isValid(at date: Date) -> Bool {
    if let validFrom, validFrom > date { return false }
    if let validUntil, validUntil <= date { return false }
    if case .until(let expiration) = retention, expiration <= date { return false }
    return true
  }

  public static func hash(_ content: String) -> String {
    SHA256.hash(data: Data(content.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

public enum FoundationModelsAgentMemoryCandidateStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case approved
  case rejected
}

public struct FoundationModelsAgentMemoryCandidateDraft: Codable, Equatable, Sendable {
  public var kind: FoundationModelsAgentMemoryKind
  public var content: String
  public var authority: FoundationModelsAgentMemoryAuthority
  public var confidence: Double
  public var importance: Double
  public var sensitivity: FoundationModelsAgentMemorySensitivity
  public var validFrom: Date?
  public var validUntil: Date?

  public init(
    kind: FoundationModelsAgentMemoryKind,
    content: String,
    authority: FoundationModelsAgentMemoryAuthority = .assistantInference,
    confidence: Double = 0.5,
    importance: Double = 0.5,
    sensitivity: FoundationModelsAgentMemorySensitivity = .personal,
    validFrom: Date? = nil,
    validUntil: Date? = nil
  ) throws {
    let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { throw FoundationModelsAgentMemoryError.emptyContent }
    self.kind = kind
    self.content = content
    self.authority = authority
    self.confidence = min(max(confidence, 0), 1)
    self.importance = min(max(importance, 0), 1)
    self.sensitivity = sensitivity
    self.validFrom = validFrom
    self.validUntil = validUntil
  }
}

public struct FoundationModelsAgentMemoryCandidate: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var scope: FoundationModelsAgentMemoryScope
  public var sourceRecordID: UUID
  public var draft: FoundationModelsAgentMemoryCandidateDraft
  public var status: FoundationModelsAgentMemoryCandidateStatus
  public var createdAt: Date
  public var decidedAt: Date?
  public var decisionReason: String?

  public init(
    id: UUID = UUID(),
    scope: FoundationModelsAgentMemoryScope,
    sourceRecordID: UUID,
    draft: FoundationModelsAgentMemoryCandidateDraft,
    status: FoundationModelsAgentMemoryCandidateStatus = .pending,
    createdAt: Date = Date(),
    decidedAt: Date? = nil,
    decisionReason: String? = nil
  ) {
    self.id = id
    self.scope = scope
    self.sourceRecordID = sourceRecordID
    self.draft = draft
    self.status = status
    self.createdAt = createdAt
    self.decidedAt = decidedAt
    self.decisionReason = decisionReason
  }
}

public enum FoundationModelsAgentMemoryConsolidationJobStatus: String, Codable, CaseIterable,
  Sendable
{
  case queued
  case processing
  case completed
  case failed
  case cancelled
}

public struct FoundationModelsAgentMemoryConsolidationJob: Codable, Equatable, Sendable,
  Identifiable
{
  public var id: UUID
  public var scope: FoundationModelsAgentMemoryScope
  public var episodeID: UUID
  public var status: FoundationModelsAgentMemoryConsolidationJobStatus
  public var attemptCount: Int
  public var maximumAttempts: Int
  public var lastError: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    scope: FoundationModelsAgentMemoryScope,
    episodeID: UUID,
    status: FoundationModelsAgentMemoryConsolidationJobStatus = .queued,
    attemptCount: Int = 0,
    maximumAttempts: Int = 3,
    lastError: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.scope = scope
    self.episodeID = episodeID
    self.status = status
    self.attemptCount = max(0, attemptCount)
    self.maximumAttempts = max(1, maximumAttempts)
    self.lastError = lastError
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }
}

public struct FoundationModelsAgentMemorySearchCandidate: Equatable, Sendable, Identifiable {
  public let id: UUID
  public let score: Double

  public init(id: UUID, score: Double) {
    self.id = id
    self.score = score
  }
}

public struct FoundationModelsAgentMemorySearchResult: Equatable, Sendable, Identifiable {
  public var id: UUID { record.id }
  public let record: FoundationModelsAgentMemoryRecord
  public let relevance: Double

  public init(record: FoundationModelsAgentMemoryRecord, relevance: Double) {
    self.record = record
    self.relevance = relevance
  }
}

public enum FoundationModelsAgentMemoryModelDestination: String, Codable, Sendable {
  case onDevice
  case remote
}

public struct FoundationModelsAgentMemoryDisclosurePolicy: Sendable {
  public let destination: FoundationModelsAgentMemoryModelDestination
  public let allowedSensitivities: Set<FoundationModelsAgentMemorySensitivity>

  public init(
    destination: FoundationModelsAgentMemoryModelDestination,
    allowedSensitivities: Set<FoundationModelsAgentMemorySensitivity>? = nil
  ) {
    self.destination = destination
    self.allowedSensitivities =
      allowedSensitivities
      ?? {
        switch destination {
        case .onDevice: Set(FoundationModelsAgentMemorySensitivity.allCases)
        case .remote: [.general, .personal]
        }
      }()
  }

  public func allows(_ sensitivity: FoundationModelsAgentMemorySensitivity) -> Bool {
    allowedSensitivities.contains(sensitivity)
  }
}

public struct FoundationModelsAgentMemoryRetrievalConfiguration: Sendable {
  public var maximumRecords: Int
  public var maximumCharacters: Int
  public var overfetchMultiplier: Int

  public init(
    maximumRecords: Int = 8,
    maximumCharacters: Int = 6_000,
    overfetchMultiplier: Int = 4
  ) {
    self.maximumRecords = max(1, maximumRecords)
    self.maximumCharacters = max(256, maximumCharacters)
    self.overfetchMultiplier = max(1, overfetchMultiplier)
  }

  public static let `default` = FoundationModelsAgentMemoryRetrievalConfiguration()
}

public struct FoundationModelsAgentMemoryTombstone: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { recordID }
  public let recordID: UUID
  public let scope: FoundationModelsAgentMemoryScope
  public let deletedAt: Date
  public let reason: String?

  public init(
    recordID: UUID,
    scope: FoundationModelsAgentMemoryScope,
    deletedAt: Date = Date(),
    reason: String? = nil
  ) {
    self.recordID = recordID
    self.scope = scope
    self.deletedAt = deletedAt
    self.reason = reason
  }
}
