import CoreAgent
import CryptoKit
import Foundation
import FoundationModels

public enum CoreAgentDeepSubagentError: Error, Equatable, Sendable {
  case emptyName
  case invalidName(String)
  case duplicateName(String)
  case emptyDescription
}

enum CoreAgentDeepSubagentIdentifier {
  static func isValidPublic(_ value: String) -> Bool {
    isValid(value)
  }

  static func isValid(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy(isHeaderScalar)
  }

  static func sanitized(_ value: String, fallback: String) -> String {
    let sanitized = String(
      value.unicodeScalars.map { scalar -> Character in
        isHeaderScalar(scalar) ? Character(scalar) : "_"
      })
    return sanitized.isEmpty ? fallback : sanitized
  }

  private static func isHeaderScalar(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 48...57, 65...90, 97...122:
      return true
    case 45, 95:
      return true
    default:
      return false
    }
  }
}

public struct CoreAgentDeepSubagentDescriptor: Codable, Equatable, Sendable {
  public let name: String
  public let description: String

  public init(name: String, description: String) {
    self.name = name
    self.description = description
  }
}

public struct CoreAgentDeepSubagentDescriptorProposal: Codable, Equatable, Sendable {
  public let proposalID: UUID
  public let name: String
  public let description: String
  public let proposalDigest: String

  public init(
    proposalID: UUID = UUID(),
    name: String,
    description: String,
    proposalDigest: String
  ) {
    self.proposalID = proposalID
    self.name = name
    self.description = description
    self.proposalDigest = proposalDigest
  }
}

public struct CoreAgentDeepSubagentDescriptorApproval: Codable, Equatable, Sendable {
  public let proposalID: UUID
  public let proposalDigest: String
  public let approvedAt: Date
  public let approverID: String

  public init(
    proposalID: UUID,
    proposalDigest: String,
    approvedAt: Date = Date(),
    approverID: String
  ) {
    self.proposalID = proposalID
    self.proposalDigest = proposalDigest
    self.approvedAt = approvedAt
    self.approverID = approverID
  }
}

public enum CoreAgentDeepSubagentRegistryError: Error, Equatable, Sendable {
  case emptyName
  case invalidName(String)
  case duplicateName(String)
  case emptyDescription
  case proposalDigestMismatch
  case proposalIDMismatch
  case subagentNameMismatch
}

public struct CoreAgentDeepSubagentDescriptorGenerationContext: Sendable {
  public let parentRunID: UUID?
  public let requestedTaskDescriptionDigest: String
  public let maxProposals: Int

  public init(
    parentRunID: UUID?,
    requestedTaskDescriptionDigest: String,
    maxProposals: Int = 4
  ) {
    self.parentRunID = parentRunID
    self.requestedTaskDescriptionDigest = requestedTaskDescriptionDigest
    self.maxProposals = max(1, maxProposals)
  }
}

public protocol CoreAgentDeepSubagentDescriptorGenerator: Sendable {
  func proposeDescriptors(
    context: CoreAgentDeepSubagentDescriptorGenerationContext
  ) async throws -> [CoreAgentDeepSubagentDescriptorProposal]
}

public enum CoreAgentDeepSubagentDescriptorProposalBuilder {
  public static func makeProposal(
    name: String,
    description: String,
    proposalID: UUID = UUID()
  ) throws -> CoreAgentDeepSubagentDescriptorProposal {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw CoreAgentDeepSubagentRegistryError.emptyName
    }
    guard CoreAgentDeepSubagentIdentifier.isValidPublic(trimmedName) else {
      throw CoreAgentDeepSubagentRegistryError.invalidName(trimmedName)
    }
    let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDescription.isEmpty else {
      throw CoreAgentDeepSubagentRegistryError.emptyDescription
    }
    return CoreAgentDeepSubagentDescriptorProposal(
      proposalID: proposalID,
      name: trimmedName,
      description: trimmedDescription,
      proposalDigest: proposalDigest(name: trimmedName, description: trimmedDescription)
    )
  }

  public static func proposalDigest(name: String, description: String) -> String {
    let payload = """
      {"description":"\(escapeJSON(description))","name":"\(escapeJSON(name))"}
      """
    return "sha256:" + sha256Hex(Data(payload.utf8))
  }

  private static func escapeJSON(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public actor CoreAgentDeepSubagentApprovedRegistry {
  private var subagents: [String: any CoreAgentDeepSubagent] = [:]

  public init(staticSubagents: [any CoreAgentDeepSubagent] = []) throws {
    var initial: [String: any CoreAgentDeepSubagent] = [:]
    for subagent in staticSubagents {
      let name = subagent.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        throw CoreAgentDeepSubagentRegistryError.emptyName
      }
      guard CoreAgentDeepSubagentIdentifier.isValidPublic(name) else {
        throw CoreAgentDeepSubagentRegistryError.invalidName(name)
      }
      let description = subagent.description.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !description.isEmpty else {
        throw CoreAgentDeepSubagentRegistryError.emptyDescription
      }
      guard initial[name] == nil else {
        throw CoreAgentDeepSubagentRegistryError.duplicateName(name)
      }
      initial[name] = subagent
    }
    self.subagents = initial
  }

  public func availableDescriptors() -> [CoreAgentDeepSubagentDescriptor] {
    subagents.values
      .map { CoreAgentDeepSubagentDescriptor(name: $0.name, description: $0.description) }
      .sorted { $0.name < $1.name }
  }

  public func subagent(named name: String) -> (any CoreAgentDeepSubagent)? {
    subagents[name]
  }

  public func register(
    subagent: any CoreAgentDeepSubagent,
    proposal: CoreAgentDeepSubagentDescriptorProposal,
    approval: CoreAgentDeepSubagentDescriptorApproval
  ) throws {
    let trimmedName = subagent.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedName == proposal.name else {
      throw CoreAgentDeepSubagentRegistryError.subagentNameMismatch
    }
    guard approval.proposalID == proposal.proposalID else {
      throw CoreAgentDeepSubagentRegistryError.proposalIDMismatch
    }
    guard approval.proposalDigest == proposal.proposalDigest else {
      throw CoreAgentDeepSubagentRegistryError.proposalDigestMismatch
    }
    try registerStatic(subagent)
  }

  private func registerStatic(_ subagent: any CoreAgentDeepSubagent) throws {
    let name = subagent.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw CoreAgentDeepSubagentRegistryError.emptyName
    }
    guard CoreAgentDeepSubagentIdentifier.isValidPublic(name) else {
      throw CoreAgentDeepSubagentRegistryError.invalidName(name)
    }
    let description = subagent.description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !description.isEmpty else {
      throw CoreAgentDeepSubagentRegistryError.emptyDescription
    }
    guard subagents[name] == nil else {
      throw CoreAgentDeepSubagentRegistryError.duplicateName(name)
    }
    subagents[name] = subagent
  }
}
