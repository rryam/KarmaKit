import Foundation

public struct CoreAgentTalonConversationID:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }

  public var description: String {
    rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    rawValue = try container.decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct CoreAgentTalonClock: Sendable {
  private let nowProvider: @Sendable () -> Date

  public init(now: @escaping @Sendable () -> Date) {
    self.nowProvider = now
  }

  public func now() -> Date {
    nowProvider()
  }

  public static let system = CoreAgentTalonClock { Date() }
}

public enum CoreAgentTalonHostError: Error, Equatable, LocalizedError, Sendable {
  case duplicateConversationID(CoreAgentTalonConversationID)

  public var errorDescription: String? {
    switch self {
    case .duplicateConversationID(let id):
      "Conversation id \(id.rawValue) is already active."
    }
  }
}

actor CoreAgentTalonAsyncLock {
  private var isLocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func withLock<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async rethrows -> Value {
    await acquire()
    defer { release() }
    return try await operation()
  }

  private func acquire() async {
    if !isLocked {
      isLocked = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func release() {
    guard !waiters.isEmpty else {
      isLocked = false
      return
    }
    waiters.removeFirst().resume()
  }
}
