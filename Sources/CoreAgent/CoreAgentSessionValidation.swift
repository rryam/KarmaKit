import CryptoKit
import Foundation
import FoundationModels

extension CoreAgentSession {
  static func makeToolsetRevision(_ manifests: [CoreAgentToolManifest]) -> String {
    let source = manifests.sorted { $0.name < $1.name }.map(\.digest).joined(separator: "\n")
    return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func makeProfileRevision(_ compatibilityID: String) -> String {
    SHA256.hash(data: Data("coreagent-profile-v1\u{0}\(compatibilityID)".utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  static func validate(
    configuration: CoreAgentConfiguration,
    toolConfiguration: CoreAgentToolConfiguration,
    transcriptRetention: CoreAgentTranscriptRetention,
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration
  ) throws {
    if let timeout = configuration.responseTimeout, timeout < .zero {
      throw CoreAgentError.invalidDuration(name: "Response timeout")
    }
    if let timeout = toolConfiguration.executionTimeout, timeout < .zero {
      throw CoreAgentError.invalidDuration(name: "Tool execution timeout")
    }
    if let limit = toolConfiguration.maximumCallsPerRun, limit < 0 {
      throw CoreAgentError.invalidToolCallLimit(limit)
    }
    guard observerDeliveryConfiguration.maximumPendingEvents > 0 else {
      throw CoreAgentError.invalidObserverQueueLimit(
        observerDeliveryConfiguration.maximumPendingEvents)
    }
    guard observerDeliveryConfiguration.defaultFlushTimeout >= .zero else {
      throw CoreAgentError.invalidDuration(name: "Observer flush timeout")
    }
    if case .preserve = configuration.transcriptErrorHandlingPolicy,
      configuration.retryPolicy.maximumAttempts > 1
    {
      throw CoreAgentError.unsafeRetryConfiguration(
        "Preserved partial transcripts cannot be retried safely. Use .revert or one attempt."
      )
    }
    try transcriptRetention.validate()
  }

  static func validate(plugins: [any CoreAgentSessionPlugin]) throws {
    var identifiers: Set<String> = []
    for plugin in plugins {
      let identifier = plugin.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !identifier.isEmpty else {
        throw CoreAgentError.emptyPluginIdentifier
      }
      guard identifiers.insert(identifier).inserted else {
        throw CoreAgentError.duplicatePluginIdentifier(identifier)
      }
    }
  }

  static func validateUniqueToolNames(_ tools: [any Tool]) throws {
    var names: Set<String> = []
    for tool in tools {
      guard names.insert(tool.name).inserted else {
        throw CoreAgentError.duplicateToolName(tool.name)
      }
    }
  }
}
