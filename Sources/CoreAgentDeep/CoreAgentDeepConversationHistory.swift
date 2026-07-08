import CoreAgent
import CryptoKit
import Foundation
import FoundationModels

public struct CoreAgentDeepConversationHistoryConfiguration: Codable, Equatable, Sendable {
  public let maximumInlineHistoryEntries: Int
  public let retainedHistoryEntries: Int
  public let summaryEntryLimit: Int
  public let summaryExcerptCharacters: Int
  public let pathPrefix: String

  public init(
    maximumInlineHistoryEntries: Int = 80,
    retainedHistoryEntries: Int = 24,
    summaryEntryLimit: Int = 12,
    summaryExcerptCharacters: Int = 240,
    pathPrefix: String = "/conversation_history"
  ) {
    self.maximumInlineHistoryEntries = maximumInlineHistoryEntries
    self.retainedHistoryEntries = retainedHistoryEntries
    self.summaryEntryLimit = summaryEntryLimit
    self.summaryExcerptCharacters = summaryExcerptCharacters
    self.pathPrefix = pathPrefix
  }
}

public enum CoreAgentDeepConversationHistoryError: Error, Equatable, Sendable {
  case invalidLimit(name: String, value: Int)
}

public struct CoreAgentDeepConversationHistoryOffload: Codable, Equatable, Sendable {
  public let id: String
  public let path: String
  public let digest: String
  public let originalHistoryEntryCount: Int
  public let offloadedHistoryEntryCount: Int
  public let retainedHistoryEntryCount: Int

  public init(
    id: String,
    path: String,
    digest: String,
    originalHistoryEntryCount: Int,
    offloadedHistoryEntryCount: Int,
    retainedHistoryEntryCount: Int
  ) {
    self.id = id
    self.path = path
    self.digest = digest
    self.originalHistoryEntryCount = originalHistoryEntryCount
    self.offloadedHistoryEntryCount = offloadedHistoryEntryCount
    self.retainedHistoryEntryCount = retainedHistoryEntryCount
  }
}

public struct CoreAgentDeepConversationHistoryCompaction: Equatable, Sendable {
  public let offload: CoreAgentDeepConversationHistoryOffload
  public let summary: String
  public let compactedTranscript: Transcript

  public init(
    offload: CoreAgentDeepConversationHistoryOffload,
    summary: String,
    compactedTranscript: Transcript
  ) {
    self.offload = offload
    self.summary = summary
    self.compactedTranscript = compactedTranscript
  }
}

public enum CoreAgentDeepConversationHistoryCompactionDecision: Equatable, Sendable {
  case unchanged(Transcript)
  case compacted(CoreAgentDeepConversationHistoryCompaction)
}

public struct CoreAgentDeepConversationHistoryEnvelope: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let artifactID: String
  public let scopeDigest: String
  public let digest: String
  public let originalHistoryEntryCount: Int
  public let retainedHistoryEntryCount: Int
  public let offloadedHistoryEntryCount: Int
  public let transcript: Transcript

  public init(
    schemaVersion: Int = 1,
    artifactID: String,
    scopeDigest: String,
    digest: String,
    originalHistoryEntryCount: Int,
    retainedHistoryEntryCount: Int,
    offloadedHistoryEntryCount: Int,
    transcript: Transcript
  ) {
    self.schemaVersion = schemaVersion
    self.artifactID = artifactID
    self.scopeDigest = scopeDigest
    self.digest = digest
    self.originalHistoryEntryCount = originalHistoryEntryCount
    self.retainedHistoryEntryCount = retainedHistoryEntryCount
    self.offloadedHistoryEntryCount = offloadedHistoryEntryCount
    self.transcript = transcript
  }
}

public struct CoreAgentDeepConversationHistoryCompactor: Sendable {
  private let filesystem: any CoreAgentDeepFilesystemBackend
  private let configuration: CoreAgentDeepConversationHistoryConfiguration
  private let redactionPolicy: CoreAgentRedactionPolicy

  public init(
    filesystem: any CoreAgentDeepFilesystemBackend,
    configuration: CoreAgentDeepConversationHistoryConfiguration = .init(),
    redactionPolicy: CoreAgentRedactionPolicy = .standard
  ) {
    self.filesystem = filesystem
    self.configuration = configuration
    self.redactionPolicy = redactionPolicy
  }

  public func compact(
    transcript: Transcript,
    scopeID: String
  ) async throws -> CoreAgentDeepConversationHistoryCompactionDecision {
    try validate(configuration)
    guard transcript.history.count > configuration.maximumInlineHistoryEntries else {
      return .unchanged(transcript)
    }

    let retainedHistory = retainedCompleteHistory(from: transcript.history)
    let offloadedHistoryEntryCount = transcript.history.count - retainedHistory.count
    guard offloadedHistoryEntryCount > 0 else {
      return .unchanged(transcript)
    }

    let transcriptDigest = try digest(for: transcript)
    let scopeDigest = digest(for: scopeID)
    let artifactID = artifactID(scopeDigest: scopeDigest, transcriptDigest: transcriptDigest)
    let path = offloadPath(scopeDigest: scopeDigest, artifactID: artifactID)
    let offload = CoreAgentDeepConversationHistoryOffload(
      id: artifactID,
      path: path,
      digest: transcriptDigest,
      originalHistoryEntryCount: transcript.history.count,
      offloadedHistoryEntryCount: offloadedHistoryEntryCount,
      retainedHistoryEntryCount: retainedHistory.count
    )
    let envelope = CoreAgentDeepConversationHistoryEnvelope(
      artifactID: artifactID,
      scopeDigest: scopeDigest,
      digest: transcriptDigest,
      originalHistoryEntryCount: transcript.history.count,
      retainedHistoryEntryCount: retainedHistory.count,
      offloadedHistoryEntryCount: offloadedHistoryEntryCount,
      transcript: transcript
    )
    try await filesystem.writeFile(try encodeEnvelope(envelope), at: path)

    let summary = summaryMessage(
      offload: offload,
      offloadedHistory: Array(transcript.history.prefix(offloadedHistoryEntryCount))
    )
    var compacted = transcript
    compacted.history = ArraySlice([summaryEntry(summary)] + retainedHistory)
    return .compacted(
      CoreAgentDeepConversationHistoryCompaction(
        offload: offload,
        summary: summary,
        compactedTranscript: compacted
      )
    )
  }

  public func prepareForCheckpoint(
    transcript: Transcript,
    scopeID: String
  ) async throws -> CoreAgentTranscriptRetentionPreparation {
    try validate(configuration)
    guard transcript.history.count > configuration.maximumInlineHistoryEntries else {
      return CoreAgentTranscriptRetentionPreparation(transcript: transcript)
    }

    let retainedHistory = retainedCompleteHistory(from: transcript.history)
    let offloadedHistoryEntryCount = transcript.history.count - retainedHistory.count
    guard offloadedHistoryEntryCount > 0 else {
      return CoreAgentTranscriptRetentionPreparation(transcript: transcript)
    }

    let transcriptDigest = try digest(for: transcript)
    let scopeDigest = digest(for: scopeID)
    let artifactID = artifactID(scopeDigest: scopeDigest, transcriptDigest: transcriptDigest)
    let finalPath = offloadPath(scopeDigest: scopeDigest, artifactID: artifactID)
    let pendingPath = pendingOffloadPath(scopeDigest: scopeDigest, artifactID: artifactID)
    try await verifyDeleteCapability(scopeDigest: scopeDigest)
    let finalPathAlreadyExisted = try await filesystem.fileExists(at: finalPath)

    let offload = CoreAgentDeepConversationHistoryOffload(
      id: artifactID,
      path: finalPath,
      digest: transcriptDigest,
      originalHistoryEntryCount: transcript.history.count,
      offloadedHistoryEntryCount: offloadedHistoryEntryCount,
      retainedHistoryEntryCount: retainedHistory.count
    )
    let envelope = CoreAgentDeepConversationHistoryEnvelope(
      artifactID: artifactID,
      scopeDigest: scopeDigest,
      digest: transcriptDigest,
      originalHistoryEntryCount: transcript.history.count,
      retainedHistoryEntryCount: retainedHistory.count,
      offloadedHistoryEntryCount: offloadedHistoryEntryCount,
      transcript: transcript
    )
    let envelopeString = try encodeEnvelope(envelope)
    try await filesystem.writeFile(envelopeString, at: pendingPath)

    let summary = summaryMessage(
      offload: offload,
      offloadedHistory: Array(transcript.history.prefix(offloadedHistoryEntryCount))
    )
    var compacted = transcript
    compacted.history = ArraySlice([summaryEntry(summary)] + retainedHistory)
    let artifact = CoreAgentCheckpointArtifact(
      id: artifactID,
      kind: Self.checkpointArtifactKind,
      path: finalPath,
      digest: transcriptDigest
    )
    return CoreAgentTranscriptRetentionPreparation(
      transcript: compacted,
      artifacts: [artifact],
      activeSessionTranscript: compacted,
      finalize: {
        try await filesystem.writeFile(envelopeString, at: finalPath)
        try await filesystem.deleteFile(at: pendingPath)
      },
      rollback: {
        try? await filesystem.deleteFile(at: pendingPath)
        if !finalPathAlreadyExisted {
          try? await filesystem.deleteFile(at: finalPath)
        }
      }
    )
  }

  public func removeCheckpointArtifacts(_ artifacts: [CoreAgentCheckpointArtifact]) async throws {
    for artifact in artifacts where ownsCheckpointArtifact(artifact) {
      try await filesystem.deleteFile(at: artifact.path)
    }
  }

  public static let checkpointArtifactKind = "coreagent.deep.conversation_history.v1"

  private func validate(_ configuration: CoreAgentDeepConversationHistoryConfiguration) throws {
    let limits = [
      ("maximumInlineHistoryEntries", configuration.maximumInlineHistoryEntries),
      ("retainedHistoryEntries", configuration.retainedHistoryEntries),
      ("summaryEntryLimit", configuration.summaryEntryLimit),
      ("summaryExcerptCharacters", configuration.summaryExcerptCharacters),
    ]
    for (name, value) in limits where value < 0 {
      throw CoreAgentDeepConversationHistoryError.invalidLimit(name: name, value: value)
    }
  }

  private func retainedCompleteHistory(
    from history: ArraySlice<Transcript.Entry>
  ) -> [Transcript.Entry] {
    guard configuration.retainedHistoryEntries > 0 else { return [] }
    let turns = completeTurns(in: history)
    var retainedTurns: [[Transcript.Entry]] = []
    var retainedCount = 0
    for turn in turns.reversed() {
      guard retainedCount + turn.count <= configuration.retainedHistoryEntries else {
        break
      }
      retainedTurns.append(turn)
      retainedCount += turn.count
    }
    return retainedTurns.reversed().flatMap { $0 }
  }

  private func completeTurns(
    in history: ArraySlice<Transcript.Entry>
  ) -> [[Transcript.Entry]] {
    var turns: [[Transcript.Entry]] = []
    var current: [Transcript.Entry] = []
    for entry in history {
      if case .prompt = entry {
        if !current.isEmpty {
          turns.append(current)
        }
        current = [entry]
      } else if !current.isEmpty {
        current.append(entry)
      }
    }
    if !current.isEmpty {
      turns.append(current)
    }
    return turns
  }

  private func summaryMessage(
    offload: CoreAgentDeepConversationHistoryOffload,
    offloadedHistory: [Transcript.Entry]
  ) -> String {
    let sampledEntries =
      offloadedHistory
      .prefix(configuration.summaryEntryLimit)
      .compactMap(entrySummary)
    let entries =
      sampledEntries.isEmpty
      ? "- No text-only excerpts were available."
      : sampledEntries.map { "- \($0)" }.joined(separator: "\n")
    return """
      COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1 artifact_id=\(offload.id) offloaded_entries=\(offload.offloadedHistoryEntryCount) retained_entries=\(offload.retainedHistoryEntryCount) original_history_entries=\(offload.originalHistoryEntryCount)
      The full native transcript snapshot is registered as checkpoint artifact metadata. This summary is a lossy projection for continuity only.

      Summary excerpts:
      \(entries)
      """
  }

  private func entrySummary(_ entry: Transcript.Entry) -> String? {
    guard let role = roleName(for: entry) else { return nil }
    let text = truncated(redactionPolicy.redact(textContent(for: entry)))
    guard !text.isEmpty else { return "\(role): [non-text content]" }
    return "\(role): \(text)"
  }

  private func roleName(for entry: Transcript.Entry) -> String? {
    switch entry {
    case .instructions:
      return "instructions"
    case .prompt:
      return "prompt"
    case .toolCalls:
      return "tool_calls"
    case .toolOutput:
      return "tool_output"
    case .response:
      return "response"
    case .reasoning:
      return nil
    @unknown default:
      return "unknown"
    }
  }

  private func textContent(for entry: Transcript.Entry) -> String {
    switch entry {
    case .instructions(let instructions):
      return textContent(in: instructions.segments)
    case .prompt(let prompt):
      return textContent(in: prompt.segments)
    case .toolCalls(let calls):
      return calls.map { CoreAgentArgumentAudit.redactedJSONString($0.arguments) }
        .joined(separator: " ")
    case .toolOutput(let output):
      return textContent(in: output.segments)
    case .response(let response):
      return textContent(in: response.segments)
    case .reasoning(let reasoning):
      return textContent(in: reasoning.segments)
    @unknown default:
      return ""
    }
  }

  private func textContent(in segments: [Transcript.Segment]) -> String {
    segments.compactMap { segment -> String? in
      guard case .text(let text) = segment else { return nil }
      return text.content
    }.joined(separator: " ")
  }

  private func truncated(_ text: String) -> String {
    guard configuration.summaryExcerptCharacters > 0 else { return "" }
    guard text.count > configuration.summaryExcerptCharacters else { return text }
    let end = text.index(text.startIndex, offsetBy: configuration.summaryExcerptCharacters)
    return String(text[..<end]) + "..."
  }

  private func summaryEntry(_ content: String) -> Transcript.Entry {
    .prompt(.init(segments: [.text(.init(content: content))]))
  }

  private func digest(for transcript: Transcript) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(transcript)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func digest(for value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func encodeEnvelope(_ envelope: CoreAgentDeepConversationHistoryEnvelope) throws
    -> String
  {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(envelope)
    return String(decoding: data, as: UTF8.self)
  }

  private func artifactID(scopeDigest: String, transcriptDigest: String) -> String {
    "conversation-history-" + digest(for: "\(scopeDigest)\u{0}\(transcriptDigest)").prefix(24)
  }

  private func offloadPath(scopeDigest: String, artifactID: String) -> String {
    "\(normalizedPathPrefix(configuration.pathPrefix))/\(scopeDigest)/\(artifactID).json"
  }

  private func pendingOffloadPath(scopeDigest: String, artifactID: String) -> String {
    "\(normalizedPathPrefix(configuration.pathPrefix))/\(scopeDigest)/.pending-\(artifactID).json"
  }

  private func ownsCheckpointArtifact(_ artifact: CoreAgentCheckpointArtifact) -> Bool {
    guard artifact.kind == Self.checkpointArtifactKind,
      isManagedArtifactID(artifact.id),
      isLowercaseHex(artifact.digest, count: 64)
    else {
      return false
    }
    let prefix = normalizedPathPrefix(configuration.pathPrefix)
    guard artifact.path.hasPrefix(prefix + "/"), artifact.path.hasSuffix(".json") else {
      return false
    }
    let suffix = artifact.path.dropFirst(prefix.count + 1)
    let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2,
      isLowercaseHex(components[0], count: 64),
      components[1] == "\(artifact.id).json"
    else {
      return false
    }
    return true
  }

  private func isManagedArtifactID(_ value: String) -> Bool {
    let prefix = "conversation-history-"
    guard value.hasPrefix(prefix) else { return false }
    return isLowercaseHex(String(value.dropFirst(prefix.count)), count: 24)
  }

  private func isLowercaseHex(_ value: String, count: Int) -> Bool {
    isLowercaseHex(Substring(value), count: count)
  }

  private func isLowercaseHex(_ value: Substring, count: Int) -> Bool {
    guard value.count == count else { return false }
    return value.allSatisfy { character in
      ("0"..."9").contains(character) || ("a"..."f").contains(character)
    }
  }

  private func normalizedPathPrefix(_ prefix: String) -> String {
    let prefixed = prefix.hasPrefix("/") ? prefix : "/" + prefix
    guard prefixed.count > 1, prefixed.hasSuffix("/") else {
      return prefixed
    }
    return String(prefixed.dropLast())
  }

  private func verifyDeleteCapability(scopeDigest: String) async throws {
    let path = "\(normalizedPathPrefix(configuration.pathPrefix))/\(scopeDigest)/.delete-probe"
    try await filesystem.writeFile("", at: path)
    try await filesystem.deleteFile(at: path)
  }
}

extension CoreAgentTranscriptRetention {
  public static func deepConversationHistory(
    filesystem: any CoreAgentDeepFilesystemBackend,
    configuration: CoreAgentDeepConversationHistoryConfiguration = .init(),
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    scopeID: @escaping @Sendable () async -> String
  ) -> CoreAgentTranscriptRetention {
    .customPreparation(
      prepare: { transcript in
        let compactor = CoreAgentDeepConversationHistoryCompactor(
          filesystem: filesystem,
          configuration: configuration,
          redactionPolicy: redactionPolicy
        )
        return try await compactor.prepareForCheckpoint(
          transcript: transcript,
          scopeID: await scopeID()
        )
      },
      remove: { artifacts in
        let compactor = CoreAgentDeepConversationHistoryCompactor(
          filesystem: filesystem,
          configuration: configuration,
          redactionPolicy: redactionPolicy
        )
        try await compactor.removeCheckpointArtifacts(artifacts)
      })
  }
}
