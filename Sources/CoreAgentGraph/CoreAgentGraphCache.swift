import Foundation

public struct CoreAgentGraphCacheKey:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  public init(stringLiteral value: String) {
    self.init(value)
  }

  public var description: String { rawValue }
}

public struct CoreAgentGraphCachePolicy<State: Sendable>: Sendable {
  public typealias KeyFunction =
    @Sendable (State, CoreAgentGraphRuntimeContext) throws
    -> CoreAgentGraphCacheKey

  public let ttl: TimeInterval?
  private let keyFunction: KeyFunction

  public init(
    ttl: TimeInterval? = nil,
    key: @escaping KeyFunction
  ) {
    self.ttl = ttl
    self.keyFunction = key
  }

  public func key(
    for state: State,
    context: CoreAgentGraphRuntimeContext
  ) throws -> CoreAgentGraphCacheKey {
    try keyFunction(state, context)
  }
}

public struct CoreAgentGraphCacheEntry<State: Sendable>: Sendable {
  public let update: State
  public let storedAt: Date
  public let expiresAt: Date?

  public init(
    update: State,
    storedAt: Date = Date(),
    expiresAt: Date? = nil
  ) {
    self.update = update
    self.storedAt = storedAt
    self.expiresAt = expiresAt
  }

  public func isExpired(at now: Date = Date()) -> Bool {
    guard let expiresAt else { return false }
    return expiresAt <= now
  }
}

extension CoreAgentGraphCacheEntry: Equatable where State: Equatable {}
extension CoreAgentGraphCacheEntry: Codable where State: Codable {}

public protocol CoreAgentGraphNodeCache<State>: Sendable {
  associatedtype State: Sendable

  func entry(
    forKey key: CoreAgentGraphCacheKey,
    nodeID: CoreAgentGraphNodeID,
    now: Date
  ) async throws -> CoreAgentGraphCacheEntry<State>?

  func store(
    _ entry: CoreAgentGraphCacheEntry<State>,
    forKey key: CoreAgentGraphCacheKey,
    nodeID: CoreAgentGraphNodeID
  ) async throws
}

public actor InMemoryCoreAgentGraphNodeCache<State: Sendable>: CoreAgentGraphNodeCache {
  private struct Scope: Hashable {
    let nodeID: CoreAgentGraphNodeID
    let key: CoreAgentGraphCacheKey
  }

  private var entries: [Scope: CoreAgentGraphCacheEntry<State>] = [:]

  public init() {}

  public func entry(
    forKey key: CoreAgentGraphCacheKey,
    nodeID: CoreAgentGraphNodeID,
    now: Date = Date()
  ) -> CoreAgentGraphCacheEntry<State>? {
    let scope = Scope(nodeID: nodeID, key: key)
    guard let entry = entries[scope] else { return nil }
    if entry.isExpired(at: now) {
      entries.removeValue(forKey: scope)
      return nil
    }
    return entry
  }

  public func store(
    _ entry: CoreAgentGraphCacheEntry<State>,
    forKey key: CoreAgentGraphCacheKey,
    nodeID: CoreAgentGraphNodeID
  ) {
    entries[Scope(nodeID: nodeID, key: key)] = entry
  }
}
