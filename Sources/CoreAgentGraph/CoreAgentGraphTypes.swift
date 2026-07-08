import Foundation

public struct CoreAgentGraphNodeID:
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

  public var description: String {
    rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct CoreAgentGraphRunID:
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

  public static func make() -> Self {
    CoreAgentGraphRunID(UUID().uuidString.lowercased())
  }
}

public struct CoreAgentGraphTaskID:
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
