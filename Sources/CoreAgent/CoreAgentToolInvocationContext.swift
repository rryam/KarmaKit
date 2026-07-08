import Foundation

public struct CoreAgentToolInvocationContext: Codable, Equatable, Sendable {
  public let runID: UUID
  public let invocationID: UUID
  public let toolName: String
  public let manifestDigest: String

  public init(
    runID: UUID,
    invocationID: UUID,
    toolName: String,
    manifestDigest: String
  ) {
    self.runID = runID
    self.invocationID = invocationID
    self.toolName = toolName
    self.manifestDigest = manifestDigest
  }
}

public enum CoreAgentToolInvocation {
  @TaskLocal package static var activeContext: CoreAgentToolInvocationContext?

  public static var current: CoreAgentToolInvocationContext? {
    activeContext
  }

  package static func withCurrent<Value>(
    _ context: CoreAgentToolInvocationContext,
    operation: @escaping () async throws -> Value
  ) async rethrows -> Value {
    try await $activeContext.withValue(context, operation: operation)
  }
}
