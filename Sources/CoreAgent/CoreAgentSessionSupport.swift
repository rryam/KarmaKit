import CryptoKit
import Foundation
import FoundationModels

struct PreparedPluginContext: Sendable {
  let contextBlocks: [CoreAgentContextBlock]
  let sanitizationFailurePolicy: CoreAgentPluginFailurePolicy

  static let empty = PreparedPluginContext(
    contextBlocks: [],
    sanitizationFailurePolicy: .recordAndContinue
  )
}

struct CoreAgentPersistedTranscript: Sendable {
  let checkpoint: CoreAgentCheckpoint
  let activeSessionTranscript: Transcript?
  let savedToCheckpointStore: Bool
}

final class NativeResponseBox<Content: Generable>: @unchecked Sendable {
  let response: LanguageModelSession.Response<Content>

  init(_ response: LanguageModelSession.Response<Content>) {
    self.response = response
  }
}

final class NativeStreamSnapshotBox<Content: Generable>: @unchecked Sendable {
  let snapshot: LanguageModelSession.ResponseStream<Content>.Snapshot

  init(_ snapshot: LanguageModelSession.ResponseStream<Content>.Snapshot) {
    self.snapshot = snapshot
  }
}

actor StreamAttemptState {
  private(set) var emittedSnapshot = false

  func markSnapshotEmitted() {
    emittedSnapshot = true
  }
}
