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
    let sanitized = String(value.unicodeScalars.map { scalar -> Character in
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

public struct CoreAgentDeepSubagentBudget: Codable, Equatable, Sendable {
  public let maximumDepth: Int?
  public let maximumDelegations: Int?
  public let maximumTotalTokens: Int?

  public init(
    maximumDepth: Int? = nil,
    maximumDelegations: Int? = nil,
    maximumTotalTokens: Int? = nil
  ) {
    self.maximumDepth = maximumDepth.map { max(0, $0) }
    self.maximumDelegations = maximumDelegations.map { max(0, $0) }
    self.maximumTotalTokens = maximumTotalTokens.map { max(0, $0) }
  }

  public static let unlimited = CoreAgentDeepSubagentBudget()
  public static let modelFacingDefault = CoreAgentDeepSubagentBudget(
    maximumDepth: 4,
    maximumDelegations: 16
  )
}

public struct CoreAgentDeepSubagentBudgetState: Codable, Equatable, Sendable {
  public let depth: Int
  public let maximumDepth: Int?
  public let delegationsUsed: Int
  public let maximumDelegations: Int?
  public let totalTokensUsed: Int
  public let maximumTotalTokens: Int?

  public init(
    depth: Int,
    maximumDepth: Int?,
    delegationsUsed: Int,
    maximumDelegations: Int?,
    totalTokensUsed: Int = 0,
    maximumTotalTokens: Int? = nil
  ) {
    self.depth = depth
    self.maximumDepth = maximumDepth
    self.delegationsUsed = delegationsUsed
    self.maximumDelegations = maximumDelegations
    self.totalTokensUsed = totalTokensUsed
    self.maximumTotalTokens = maximumTotalTokens
  }
}

public enum CoreAgentDeepSubagentBudgetError:
  Error, Equatable, LocalizedError, Sendable
{
  case maxDepthExceeded(maximumDepth: Int, attemptedDepth: Int)
  case delegationLimitExceeded(maximumDelegations: Int)
  case tokenBudgetExceeded(maximumTotalTokens: Int, totalTokensUsed: Int)

  public var errorDescription: String? {
    switch self {
    case .maxDepthExceeded(let maximumDepth, let attemptedDepth):
      "Subagent recursion depth \(attemptedDepth) exceeds the configured maximum depth \(maximumDepth)."
    case .delegationLimitExceeded(let maximumDelegations):
      "Subagent delegation budget exhausted after \(maximumDelegations) delegation(s)."
    case .tokenBudgetExceeded(let maximumTotalTokens, let totalTokensUsed):
      "Subagent token budget exhausted after \(totalTokensUsed) token(s); configured maximum is \(maximumTotalTokens)."
    }
  }
}

private actor CoreAgentDeepSubagentBudgetTracker {
  private let budget: CoreAgentDeepSubagentBudget
  private var delegationsUsed = 0
  private var totalTokensUsed = 0

  init(budget: CoreAgentDeepSubagentBudget) {
    self.budget = budget
  }

  func reserve(attemptedDepth: Int) throws -> CoreAgentDeepSubagentBudgetState {
    if let maximumDepth = budget.maximumDepth, attemptedDepth > maximumDepth {
      throw CoreAgentDeepSubagentBudgetError.maxDepthExceeded(
        maximumDepth: maximumDepth,
        attemptedDepth: attemptedDepth
      )
    }
    if let maximumDelegations = budget.maximumDelegations,
      delegationsUsed >= maximumDelegations
    {
      throw CoreAgentDeepSubagentBudgetError.delegationLimitExceeded(
        maximumDelegations: maximumDelegations
      )
    }
    if let maximumTotalTokens = budget.maximumTotalTokens,
      totalTokensUsed >= maximumTotalTokens
    {
      throw CoreAgentDeepSubagentBudgetError.tokenBudgetExceeded(
        maximumTotalTokens: maximumTotalTokens,
        totalTokensUsed: totalTokensUsed
      )
    }
    delegationsUsed += 1
    return currentState(depth: attemptedDepth)
  }

  func recordUsage(
    _ usage: CoreAgentUsage?,
    depth: Int
  ) throws -> CoreAgentDeepSubagentBudgetState {
    if let usage {
      totalTokensUsed += usage.totalTokenCount
    }
    if let maximumTotalTokens = budget.maximumTotalTokens,
      totalTokensUsed > maximumTotalTokens
    {
      throw CoreAgentDeepSubagentBudgetError.tokenBudgetExceeded(
        maximumTotalTokens: maximumTotalTokens,
        totalTokensUsed: totalTokensUsed
      )
    }
    return currentState(depth: depth)
  }

  func currentState(depth: Int) -> CoreAgentDeepSubagentBudgetState {
    CoreAgentDeepSubagentBudgetState(
      depth: depth,
      maximumDepth: budget.maximumDepth,
      delegationsUsed: delegationsUsed,
      maximumDelegations: budget.maximumDelegations,
      totalTokensUsed: totalTokensUsed,
      maximumTotalTokens: budget.maximumTotalTokens
    )
  }
}

private actor CoreAgentDeepSubagentBudgetRegistry {
  private var trackers: [UUID: CoreAgentDeepSubagentBudgetTracker] = [:]

  func tracker(
    for rootID: UUID,
    budget: CoreAgentDeepSubagentBudget
  ) -> CoreAgentDeepSubagentBudgetTracker {
    if let tracker = trackers[rootID] {
      return tracker
    }
    let tracker = CoreAgentDeepSubagentBudgetTracker(budget: budget)
    trackers[rootID] = tracker
    return tracker
  }

  func removeTracker(for rootID: UUID) {
    trackers[rootID] = nil
  }

  func removeAll() {
    trackers.removeAll()
  }

  func count() -> Int {
    trackers.count
  }
}

private enum CoreAgentDeepSubagentBudgetContext {
  struct Active: Sendable {
    let state: CoreAgentDeepSubagentBudgetState
    let tracker: CoreAgentDeepSubagentBudgetTracker
  }

  @TaskLocal static var current: Active?
}

public struct CoreAgentDeepSubagentRequest: Sendable {
  public let taskID: UUID
  public let subagentType: String
  public let description: String
  public let parentRunID: UUID?
  public let parentToolInvocationID: UUID?
  public let budget: CoreAgentDeepSubagentBudgetState?

  public init(
    taskID: UUID,
    subagentType: String,
    description: String,
    parentRunID: UUID? = nil,
    parentToolInvocationID: UUID? = nil,
    budget: CoreAgentDeepSubagentBudgetState? = nil
  ) {
    self.taskID = taskID
    self.subagentType = subagentType
    self.description = description
    self.parentRunID = parentRunID
    self.parentToolInvocationID = parentToolInvocationID
    self.budget = budget
  }
}

public struct CoreAgentDeepSubagentResult: Sendable {
  public let subagentName: String
  public let content: String
  public let childRunID: UUID?
  public let childReceiptRootHash: String?
  public let checkpointKey: String?
  public let transcriptEntryCount: Int?
  public let usage: CoreAgentUsage?

  public init(
    subagentName: String,
    content: String,
    childRunID: UUID? = nil,
    childReceiptRootHash: String? = nil,
    checkpointKey: String? = nil,
    transcriptEntryCount: Int? = nil,
    usage: CoreAgentUsage? = nil
  ) {
    self.subagentName = subagentName
    self.content = content
    self.childRunID = childRunID
    self.childReceiptRootHash = childReceiptRootHash
    self.checkpointKey = checkpointKey
    self.transcriptEntryCount = transcriptEntryCount
    self.usage = usage
  }
}

public struct CoreAgentDeepSubagentFailure: Error, Sendable {
  public let subagentName: String
  public let checkpointKey: String?
  public let childRunID: UUID?
  public let childReceiptRootHash: String?
  public let underlyingErrorDescription: String
  public let underlyingErrorType: String

  public init(
    subagentName: String,
    checkpointKey: String?,
    childRunID: UUID?,
    childReceiptRootHash: String?,
    underlyingError: any Error
  ) {
    self.subagentName = subagentName
    self.checkpointKey = checkpointKey
    self.childRunID = childRunID
    self.childReceiptRootHash = childReceiptRootHash
    self.underlyingErrorDescription = String(describing: underlyingError)
    self.underlyingErrorType = String(reflecting: Swift.type(of: underlyingError))
  }
}

public protocol CoreAgentDeepSubagent: Sendable {
  var name: String { get }
  var description: String { get }

  func run(request: CoreAgentDeepSubagentRequest) async throws
    -> CoreAgentDeepSubagentResult
}

public struct ClosureCoreAgentDeepSubagent: CoreAgentDeepSubagent {
  public let name: String
  public let description: String
  private let handler:
    @Sendable (CoreAgentDeepSubagentRequest) async throws -> CoreAgentDeepSubagentResult

  public init(
    name: String,
    description: String,
    handler:
      @escaping @Sendable (CoreAgentDeepSubagentRequest) async throws
        -> CoreAgentDeepSubagentResult
  ) {
    self.name = name
    self.description = description
    self.handler = handler
  }

  public func run(request: CoreAgentDeepSubagentRequest) async throws
    -> CoreAgentDeepSubagentResult
  {
    try await handler(request)
  }
}

public struct CoreAgentDeepSessionSubagent<Model: LanguageModel>: CoreAgentDeepSubagent {
  public let name: String
  public let description: String

  private let model: Model
  private let tools: [any Tool]
  private let instructions: Instructions?
  private let configuration: CoreAgentConfiguration
  private let toolConfiguration: CoreAgentToolConfiguration
  private let checkpointStore: (any CoreAgentCheckpointStore)?
  private let checkpointKey: @Sendable (CoreAgentDeepSubagentRequest) -> String
  private let transcriptRetention: CoreAgentTranscriptRetention
  private let requiresMatchingToolset: Bool
  private let plugins: [any CoreAgentSessionPlugin]
  private let metadata: @Sendable (CoreAgentDeepSubagentRequest) -> CoreAgentRequestMetadata

  public init(
    name: String,
    description: String,
    model: Model,
    tools: [any Tool] = [],
    instructions: Instructions? = nil,
    configuration: CoreAgentConfiguration = .default,
    toolConfiguration: CoreAgentToolConfiguration = .denyAll,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: (@escaping @Sendable (CoreAgentDeepSubagentRequest) -> String) =
      Self.defaultCheckpointKey,
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    requiresMatchingToolset: Bool = true,
    plugins: [any CoreAgentSessionPlugin] = [],
    metadata: (@escaping @Sendable (CoreAgentDeepSubagentRequest) -> CoreAgentRequestMetadata) =
      Self.defaultMetadata
  ) {
    self.name = name
    self.description = description
    self.model = model
    self.tools = tools
    self.instructions = instructions
    self.configuration = configuration
    self.toolConfiguration = toolConfiguration
    self.checkpointStore = checkpointStore
    self.checkpointKey = checkpointKey
    self.transcriptRetention = transcriptRetention
    self.requiresMatchingToolset = requiresMatchingToolset
    self.plugins = plugins
    self.metadata = metadata
  }

  public func run(request: CoreAgentDeepSubagentRequest) async throws
    -> CoreAgentDeepSubagentResult
  {
    let key = checkpointKey(request)
    let durableKeyCandidate = checkpointStore == nil ? nil : key
    var session: CoreAgentSession?
    do {
      let child = try CoreAgentSession(
        model: model,
        tools: tools,
        instructions: instructions,
        configuration: configuration,
        toolConfiguration: toolConfiguration,
        checkpointStore: checkpointStore,
        checkpointKey: key,
        transcriptRetention: transcriptRetention,
        requiresMatchingToolset: requiresMatchingToolset,
        plugins: plugins
      )
      session = child
      let response = try await child.respond(
        to: request.description,
        metadata: metadata(request),
        contextQuery: request.description
      )
      let receipt = try CoreAgentRunReceipt(run: response.run)
      let checkpointFailed = response.run.events.contains {
        $0.kind == .transcriptCheckpointFailed
      }
      return CoreAgentDeepSubagentResult(
        subagentName: name,
        content: response.content,
        childRunID: response.run.id,
        childReceiptRootHash: receipt.rootHash,
        checkpointKey: checkpointFailed ? nil : durableKeyCandidate,
        transcriptEntryCount: response.transcriptEntries.count,
        usage: response.usage
      )
    } catch {
      let run = await session?.lastRun()
      let checkpointFailed = run?.events.contains {
        $0.kind == .transcriptCheckpointFailed
      } ?? false
      let receipt = run.flatMap { try? CoreAgentRunReceipt(run: $0) }
      throw CoreAgentDeepSubagentFailure(
        subagentName: name,
        checkpointKey: run == nil || checkpointFailed ? nil : durableKeyCandidate,
        childRunID: run?.id,
        childReceiptRootHash: receipt?.rootHash,
        underlyingError: error
      )
    }
  }

  public static func defaultCheckpointKey(
    request: CoreAgentDeepSubagentRequest
  ) -> String {
    let subagent = sanitizePathComponent(request.subagentType)
    let taskID = request.taskID.uuidString.lowercased()
    return "coreagent-deep/subagents/\(subagent)/\(taskID)"
  }

  public static func defaultMetadata(
    request: CoreAgentDeepSubagentRequest
  ) -> CoreAgentRequestMetadata {
    [:]
  }

  private static func sanitizePathComponent(_ value: String) -> String {
    CoreAgentDeepSubagentIdentifier.sanitized(value, fallback: "subagent")
  }
}

public enum CoreAgentDeepSubagentRunStatus: String, Codable, Equatable, Sendable {
  case completed
  case denied
  case failed
}

public struct CoreAgentDeepSubagentAuditConfiguration: Sendable {
  public var redactionPolicy: CoreAgentRedactionPolicy
  public var maximumErrorCharacters: Int
  public var maximumDescriptionCharacters: Int

  public init(
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    maximumErrorCharacters: Int = 2_000,
    maximumDescriptionCharacters: Int = 2_000
  ) {
    self.redactionPolicy = redactionPolicy
    self.maximumErrorCharacters = max(0, maximumErrorCharacters)
    self.maximumDescriptionCharacters = max(0, maximumDescriptionCharacters)
  }

  public func summarize(error: any Error) -> String {
    let raw: String
    if let failure = error as? CoreAgentDeepSubagentFailure {
      raw = failure.underlyingErrorDescription
    } else {
      raw = String(describing: error)
    }
    let redacted = redactionPolicy.redact(raw)
    guard redacted.count > maximumErrorCharacters else {
      return redacted
    }
    let end = redacted.index(redacted.startIndex, offsetBy: maximumErrorCharacters)
    return "\(redacted[..<end])..."
  }

  public func errorType(for error: any Error) -> String {
    if let failure = error as? CoreAgentDeepSubagentFailure {
      return failure.underlyingErrorType
    }
    return String(reflecting: Swift.type(of: error))
  }

  public func summarize(description: String) -> String {
    let redacted = redactionPolicy.redact(description)
    guard redacted.count > maximumDescriptionCharacters else {
      return redacted
    }
    let end = redacted.index(redacted.startIndex, offsetBy: maximumDescriptionCharacters)
    return "\(redacted[..<end])..."
  }
}

public struct CoreAgentDeepSubagentAuditRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let subagentName: String
  public let description: String
  public let parentRunID: UUID?
  public let parentToolInvocationID: UUID?
  public let childRunID: UUID?
  public let childReceiptRootHash: String?
  public let checkpointKey: String?
  public let status: CoreAgentDeepSubagentRunStatus
  public let errorDescription: String?
  public let errorType: String?
  public let outputCharacterCount: Int?
  public let budgetDepth: Int?
  public let budgetDelegationsUsed: Int?
  public let budgetMaximumDepth: Int?
  public let budgetMaximumDelegations: Int?
  public let budgetTotalTokensUsed: Int?
  public let budgetMaximumTotalTokens: Int?
  public let startedAt: Date
  public let endedAt: Date

  public init(
    id: UUID,
    subagentName: String,
    description: String,
    parentRunID: UUID?,
    parentToolInvocationID: UUID?,
    childRunID: UUID?,
    childReceiptRootHash: String?,
    checkpointKey: String?,
    status: CoreAgentDeepSubagentRunStatus,
    errorDescription: String?,
    errorType: String? = nil,
    outputCharacterCount: Int?,
    budget: CoreAgentDeepSubagentBudgetState? = nil,
    startedAt: Date,
    endedAt: Date
  ) {
    self.id = id
    self.subagentName = subagentName
    self.description = description
    self.parentRunID = parentRunID
    self.parentToolInvocationID = parentToolInvocationID
    self.childRunID = childRunID
    self.childReceiptRootHash = childReceiptRootHash
    self.checkpointKey = checkpointKey
    self.status = status
    self.errorDescription = errorDescription
    self.errorType = errorType
    self.outputCharacterCount = outputCharacterCount
    self.budgetDepth = budget?.depth
    self.budgetDelegationsUsed = budget?.delegationsUsed
    self.budgetMaximumDepth = budget?.maximumDepth
    self.budgetMaximumDelegations = budget?.maximumDelegations
    self.budgetTotalTokensUsed = budget?.totalTokensUsed
    self.budgetMaximumTotalTokens = budget?.maximumTotalTokens
    self.startedAt = startedAt
    self.endedAt = endedAt
  }
}

public actor CoreAgentDeepSubagentAuditStore {
  private var values: [CoreAgentDeepSubagentAuditRecord] = []

  public init() {}

  public func append(_ record: CoreAgentDeepSubagentAuditRecord) {
    values.append(record)
  }

  public func records() -> [CoreAgentDeepSubagentAuditRecord] {
    values
  }
}

@Generable
public struct CoreAgentDeepTaskArguments: Sendable {
  public let description: String
  public let subagent_type: String

  public init(description: String, subagent_type: String) {
    self.description = description
    self.subagent_type = subagent_type
  }

  public var subagentType: String {
    subagent_type
  }
}

public struct CoreAgentDeepTaskTool: Tool, CoreAgentRunLifecycleTool {
  public let name = "task"
  public let description: String
  public let auditStore: CoreAgentDeepSubagentAuditStore

  private let registry: CoreAgentDeepSubagentApprovedRegistry
  private let descriptors: [CoreAgentDeepSubagentDescriptor]
  private let auditConfiguration: CoreAgentDeepSubagentAuditConfiguration
  private let budget: CoreAgentDeepSubagentBudget
  private let budgetRegistry = CoreAgentDeepSubagentBudgetRegistry()
  private let directBudgetRootID = UUID()

  public init(
    subagents: [any CoreAgentDeepSubagent],
    auditStore: CoreAgentDeepSubagentAuditStore = CoreAgentDeepSubagentAuditStore(),
    auditConfiguration: CoreAgentDeepSubagentAuditConfiguration =
      CoreAgentDeepSubagentAuditConfiguration(),
    budget: CoreAgentDeepSubagentBudget = .modelFacingDefault,
    description: String? = nil
  ) throws {
    self.descriptors = try Self.sortedDescriptors(from: subagents)
    self.registry = try CoreAgentDeepSubagentApprovedRegistry(staticSubagents: subagents)
    self.auditStore = auditStore
    self.auditConfiguration = auditConfiguration
    self.budget = budget
    self.description = description ?? Self.defaultDescription(descriptors: descriptors)
  }

  public init(
    registry: CoreAgentDeepSubagentApprovedRegistry,
    descriptors: [CoreAgentDeepSubagentDescriptor],
    auditStore: CoreAgentDeepSubagentAuditStore = CoreAgentDeepSubagentAuditStore(),
    auditConfiguration: CoreAgentDeepSubagentAuditConfiguration =
      CoreAgentDeepSubagentAuditConfiguration(),
    budget: CoreAgentDeepSubagentBudget = .modelFacingDefault,
    description: String? = nil
  ) {
    self.registry = registry
    self.descriptors = descriptors.sorted { $0.name < $1.name }
    self.auditStore = auditStore
    self.auditConfiguration = auditConfiguration
    self.budget = budget
    self.description = description ?? Self.defaultDescription(descriptors: self.descriptors)
  }

  public func availableSubagents() -> [CoreAgentDeepSubagentDescriptor] {
    descriptors
  }

  public func refreshedDescriptors() async -> [CoreAgentDeepSubagentDescriptor] {
    await registry.availableDescriptors()
  }

  public func coreAgentRunDidFinish(_ runID: UUID) async {
    await resetBudget(for: runID)
  }

  public func resetBudget(for rootID: UUID) async {
    await budgetRegistry.removeTracker(for: rootID)
  }

  public func resetBudgetScopes() async {
    await budgetRegistry.removeAll()
  }

  public func activeBudgetScopeCount() async -> Int {
    await budgetRegistry.count()
  }

  @concurrent
  public func call(arguments: CoreAgentDeepTaskArguments) async throws -> String {
    let requestedType = arguments.subagent_type.trimmingCharacters(in: .whitespacesAndNewlines)
    let taskDescription = arguments.description.trimmingCharacters(in: .whitespacesAndNewlines)
    let auditDescription = auditConfiguration.summarize(description: taskDescription)
    let invocation = CoreAgentToolInvocation.current
    let taskID = invocation?.invocationID ?? UUID()
    guard !taskDescription.isEmpty else {
      await appendAuditRecord(
        id: taskID,
        subagentName: CoreAgentDeepSubagentIdentifier.sanitized(
          requestedType,
          fallback: "unknown"
        ),
        description: auditDescription,
        parentRunID: invocation?.runID,
        parentToolInvocationID: invocation?.invocationID,
        status: .denied,
        errorDescription: "Task description is empty.",
        errorType: String(reflecting: CoreAgentDeepSubagentError.self),
        startedAt: Date(),
        endedAt: Date()
      )
      throw CoreAgentDeepSubagentError.emptyDescription
    }

    let startedAt = Date()
    let activeBudget = CoreAgentDeepSubagentBudgetContext.current
    let attemptedDepth = (activeBudget?.state.depth ?? 0) + 1
    let budgetTracker: CoreAgentDeepSubagentBudgetTracker
    if let activeBudget {
      budgetTracker = activeBudget.tracker
    } else {
      let rootID = invocation?.runID ?? directBudgetRootID
      budgetTracker = await budgetRegistry.tracker(for: rootID, budget: budget)
    }
    let budgetState: CoreAgentDeepSubagentBudgetState
    do {
      budgetState = try await budgetTracker.reserve(attemptedDepth: attemptedDepth)
    } catch {
      await appendAuditRecord(
        id: taskID,
        subagentName: requestedType,
        description: auditDescription,
        parentRunID: invocation?.runID,
        parentToolInvocationID: invocation?.invocationID,
        status: .denied,
        errorDescription: auditConfiguration.summarize(error: error),
        errorType: auditConfiguration.errorType(for: error),
        budget: budgetStateForDeniedBudgetError(
          error,
          attemptedDepth: attemptedDepth,
          inheritedState: activeBudget?.state
        ),
        startedAt: startedAt,
        endedAt: Date()
      )
      throw error
    }
    guard let subagent = await registry.subagent(named: requestedType) else {
      await appendAuditRecord(
        id: taskID,
        subagentName: CoreAgentDeepSubagentIdentifier.sanitized(
          requestedType,
          fallback: "unknown"
        ),
        description: auditDescription,
        parentRunID: invocation?.runID,
        parentToolInvocationID: invocation?.invocationID,
        status: .denied,
        errorDescription: "Requested subagent is not registered.",
        errorType: nil,
        budget: budgetState,
        startedAt: startedAt,
        endedAt: Date()
      )
      return unavailableSubagentMessage(requestedType)
    }

    let request = CoreAgentDeepSubagentRequest(
      taskID: taskID,
      subagentType: requestedType,
      description: taskDescription,
      parentRunID: invocation?.runID,
      parentToolInvocationID: invocation?.invocationID,
      budget: budgetState
    )
    let result: CoreAgentDeepSubagentResult
    do {
      result = try await CoreAgentDeepSubagentBudgetContext.$current.withValue(
        CoreAgentDeepSubagentBudgetContext.Active(
          state: budgetState,
          tracker: budgetTracker
        )
      ) {
        try await subagent.run(request: request)
      }
    } catch {
      let endedAt = Date()
      let failure = error as? CoreAgentDeepSubagentFailure
      await auditStore.append(
        CoreAgentDeepSubagentAuditRecord(
          id: taskID,
          subagentName: requestedType,
          description: auditDescription,
          parentRunID: request.parentRunID,
          parentToolInvocationID: request.parentToolInvocationID,
          childRunID: failure?.childRunID,
          childReceiptRootHash: failure?.childReceiptRootHash,
          checkpointKey: failure?.checkpointKey,
          status: .failed,
          errorDescription: auditConfiguration.summarize(error: error),
          errorType: auditConfiguration.errorType(for: error),
          outputCharacterCount: nil,
          budget: budgetState,
          startedAt: startedAt,
          endedAt: endedAt
        )
      )
      throw error
    }

    let recordedBudgetState: CoreAgentDeepSubagentBudgetState
    do {
      recordedBudgetState = try await budgetTracker.recordUsage(
        result.usage,
        depth: budgetState.depth
      )
    } catch {
      let endedAt = Date()
      let budgetAfterFailure = await budgetTracker.currentState(depth: budgetState.depth)
      await appendAuditRecord(
        id: taskID,
        subagentName: requestedType,
        description: auditDescription,
        parentRunID: request.parentRunID,
        parentToolInvocationID: request.parentToolInvocationID,
        status: .failed,
        errorDescription: auditConfiguration.summarize(error: error),
        errorType: auditConfiguration.errorType(for: error),
        budget: budgetAfterFailure,
        startedAt: startedAt,
        endedAt: endedAt
      )
      throw error
    }

    let endedAt = Date()
    await auditStore.append(
      CoreAgentDeepSubagentAuditRecord(
        id: taskID,
        subagentName: requestedType,
        description: auditDescription,
        parentRunID: request.parentRunID,
        parentToolInvocationID: request.parentToolInvocationID,
        childRunID: result.childRunID,
        childReceiptRootHash: result.childReceiptRootHash,
        checkpointKey: result.checkpointKey,
        status: .completed,
        errorDescription: nil,
        errorType: nil,
        outputCharacterCount: result.content.count,
        budget: recordedBudgetState,
        startedAt: startedAt,
        endedAt: endedAt
      )
    )
    return resultMessage(for: result, canonicalSubagentName: requestedType)
  }


  private static func sortedDescriptors(
    from subagents: [any CoreAgentDeepSubagent]
  ) throws -> [CoreAgentDeepSubagentDescriptor] {
    var byName: [String: CoreAgentDeepSubagentDescriptor] = [:]
    for subagent in subagents {
      let name = subagent.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        throw CoreAgentDeepSubagentError.emptyName
      }
      guard CoreAgentDeepSubagentIdentifier.isValid(name) else {
        throw CoreAgentDeepSubagentError.invalidName(name)
      }
      guard byName[name] == nil else {
        throw CoreAgentDeepSubagentError.duplicateName(name)
      }
      byName[name] = CoreAgentDeepSubagentDescriptor(
        name: name,
        description: subagent.description
      )
    }
    return byName.values.sorted { $0.name < $1.name }
  }

  private static func defaultDescription(
    descriptors: [CoreAgentDeepSubagentDescriptor]
  ) -> String {
    let agents = descriptors
      .map { "- \($0.name): \($0.description)" }
      .joined(separator: "\n")
    return """
    Launches a short-lived isolated subagent and returns one final result.
    Use this for complex, independent tasks where intermediate tool calls should stay out of the parent context.
    Arguments: description, subagent_type.

    Available subagent types:
    \(agents)
    """
  }

  private func unavailableSubagentMessage(_ requestedType: String) -> String {
    let allowed = descriptors.map(\.name).joined(separator: ", ")
    return """
    COREAGENT_DEEP_SUBAGENT_UNAVAILABLE_V1 requested=\(CoreAgentDeepSubagentIdentifier.sanitized(requestedType, fallback: "unknown"))
    Allowed subagent types: \(allowed)
    """
  }

  private func resultMessage(
    for result: CoreAgentDeepSubagentResult,
    canonicalSubagentName: String
  ) -> String {
    var metadata = [
      "COREAGENT_DEEP_SUBAGENT_RESULT_V1 subagent=\(canonicalSubagentName)"
    ]
    if let childRunID = result.childRunID {
      metadata.append("child_run_id=\(childRunID.uuidString.lowercased())")
    }
    if let childReceiptRootHash = result.childReceiptRootHash {
      metadata.append("child_receipt_root_hash=\(childReceiptRootHash)")
    }
    if let checkpointKey = result.checkpointKey {
      metadata.append("checkpoint_key=\(checkpointKey)")
    }
    return """
    \(metadata.joined(separator: " "))
    \(result.content)
    """
  }

  private func appendAuditRecord(
    id: UUID,
    subagentName: String,
    description: String,
    parentRunID: UUID?,
    parentToolInvocationID: UUID?,
    status: CoreAgentDeepSubagentRunStatus,
    errorDescription: String?,
    errorType: String?,
    budget: CoreAgentDeepSubagentBudgetState? = nil,
    startedAt: Date,
    endedAt: Date
  ) async {
    await auditStore.append(
      CoreAgentDeepSubagentAuditRecord(
        id: id,
        subagentName: subagentName,
        description: description,
        parentRunID: parentRunID,
        parentToolInvocationID: parentToolInvocationID,
        childRunID: nil,
        childReceiptRootHash: nil,
        checkpointKey: nil,
        status: status,
        errorDescription: errorDescription,
        errorType: errorType,
        outputCharacterCount: nil,
        budget: budget,
        startedAt: startedAt,
        endedAt: endedAt
      )
    )
  }

  private func budgetStateForDeniedBudgetError(
    _ error: any Error,
    attemptedDepth: Int,
    inheritedState: CoreAgentDeepSubagentBudgetState?
  ) -> CoreAgentDeepSubagentBudgetState? {
    switch error {
    case .maxDepthExceeded(let maximumDepth, _) as CoreAgentDeepSubagentBudgetError:
      CoreAgentDeepSubagentBudgetState(
        depth: attemptedDepth,
        maximumDepth: maximumDepth,
        delegationsUsed: inheritedState?.delegationsUsed ?? 0,
        maximumDelegations: inheritedState?.maximumDelegations ?? budget.maximumDelegations,
        totalTokensUsed: inheritedState?.totalTokensUsed ?? 0,
        maximumTotalTokens: inheritedState?.maximumTotalTokens ?? budget.maximumTotalTokens
      )
    case .delegationLimitExceeded(let maximumDelegations) as CoreAgentDeepSubagentBudgetError:
      CoreAgentDeepSubagentBudgetState(
        depth: attemptedDepth,
        maximumDepth: inheritedState?.maximumDepth ?? budget.maximumDepth,
        delegationsUsed: maximumDelegations,
        maximumDelegations: maximumDelegations,
        totalTokensUsed: inheritedState?.totalTokensUsed ?? 0,
        maximumTotalTokens: inheritedState?.maximumTotalTokens ?? budget.maximumTotalTokens
      )
    case .tokenBudgetExceeded(let maximumTotalTokens, let totalTokensUsed)
      as CoreAgentDeepSubagentBudgetError:
      CoreAgentDeepSubagentBudgetState(
        depth: attemptedDepth,
        maximumDepth: inheritedState?.maximumDepth ?? budget.maximumDepth,
        delegationsUsed: inheritedState?.delegationsUsed ?? 0,
        maximumDelegations: inheritedState?.maximumDelegations ?? budget.maximumDelegations,
        totalTokensUsed: totalTokensUsed,
        maximumTotalTokens: maximumTotalTokens
      )
    default:
      nil
    }
  }
}

public struct CoreAgentDeepSubagentsPlugin: CoreAgentSessionPlugin {
  public let identifier: String
  public let taskTool: CoreAgentDeepTaskTool

  public var tools: [any Tool] {
    [taskTool]
  }

  public init(
    identifier: String = "coreagent.deep.subagents",
    subagents: [any CoreAgentDeepSubagent],
    auditStore: CoreAgentDeepSubagentAuditStore = CoreAgentDeepSubagentAuditStore(),
    auditConfiguration: CoreAgentDeepSubagentAuditConfiguration =
      CoreAgentDeepSubagentAuditConfiguration(),
    budget: CoreAgentDeepSubagentBudget = .modelFacingDefault
  ) throws {
    self.identifier = identifier
    self.taskTool = try CoreAgentDeepTaskTool(
      subagents: subagents,
      auditStore: auditStore,
      auditConfiguration: auditConfiguration,
      budget: budget
    )
  }

  public func didComplete(_ completion: CoreAgentPluginCompletion) async throws
    -> [CoreAgentPluginEvent]
  {
    await taskTool.resetBudget(for: completion.runID)
    return []
  }

  public func didFail(_ failure: CoreAgentPluginFailure) async -> [CoreAgentPluginEvent] {
    await taskTool.resetBudget(for: failure.runID)
    return []
  }
}
