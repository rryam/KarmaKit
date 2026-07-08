import Foundation

public struct CoreAgentGraphStoreNamespace:
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

  public static let `default` = CoreAgentGraphStoreNamespace("default")
}

public struct CoreAgentGraphStoreKey:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible, Comparable
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

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct CoreAgentGraphStoreRecord<Value: Sendable>: Sendable {
  public let namespace: CoreAgentGraphStoreNamespace
  public let key: CoreAgentGraphStoreKey
  public let value: Value
  public let updatedAt: Date

  public init(
    namespace: CoreAgentGraphStoreNamespace = .default,
    key: CoreAgentGraphStoreKey,
    value: Value,
    updatedAt: Date = Date()
  ) {
    self.namespace = namespace
    self.key = key
    self.value = value
    self.updatedAt = updatedAt
  }
}

extension CoreAgentGraphStoreRecord: Equatable where Value: Equatable {}
extension CoreAgentGraphStoreRecord: Codable where Value: Codable {}

public protocol CoreAgentGraphStore<Value>: Sendable {
  associatedtype Value: Sendable

  func put(
    _ value: Value,
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace
  ) async throws

  func value(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace
  ) async throws -> Value?

  func record(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace
  ) async throws -> CoreAgentGraphStoreRecord<Value>?

  func removeValue(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace
  ) async throws

  func keys(namespace: CoreAgentGraphStoreNamespace) async throws -> [CoreAgentGraphStoreKey]
}

public actor InMemoryCoreAgentGraphStore<Value: Sendable>: CoreAgentGraphStore {
  private struct Scope: Hashable {
    let namespace: CoreAgentGraphStoreNamespace
    let key: CoreAgentGraphStoreKey
  }

  private var records: [Scope: CoreAgentGraphStoreRecord<Value>] = [:]

  public init() {}

  public func put(
    _ value: Value,
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace = .default
  ) {
    let scope = Scope(namespace: namespace, key: key)
    records[scope] = CoreAgentGraphStoreRecord(namespace: namespace, key: key, value: value)
  }

  public func value(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace = .default
  ) -> Value? {
    record(forKey: key, namespace: namespace)?.value
  }

  public func record(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace = .default
  ) -> CoreAgentGraphStoreRecord<Value>? {
    records[Scope(namespace: namespace, key: key)]
  }

  public func removeValue(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace = .default
  ) {
    records.removeValue(forKey: Scope(namespace: namespace, key: key))
  }

  public func keys(
    namespace: CoreAgentGraphStoreNamespace = .default
  ) -> [CoreAgentGraphStoreKey] {
    records.keys.compactMap { scope in
      scope.namespace == namespace ? scope.key : nil
    }.sorted()
  }
}
