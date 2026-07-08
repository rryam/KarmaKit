import Foundation

public struct CoreAgentGraphInterruptID:
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
    CoreAgentGraphInterruptID(UUID().uuidString.lowercased())
  }
}

public struct CoreAgentGraphResumeValue: Codable, Equatable, Sendable {
  public let encodedValue: Data

  public init<Value: Codable & Sendable>(_ value: Value) throws {
    self.encodedValue = try JSONEncoder().encode(value)
  }

  public func decode<Value: Codable & Sendable>(as type: Value.Type = Value.self) throws -> Value {
    try JSONDecoder().decode(type, from: encodedValue)
  }
}

public struct CoreAgentGraphCommand: Equatable, Sendable {
  public let resumeValue: CoreAgentGraphResumeValue?

  private init(resumeValue: CoreAgentGraphResumeValue?) {
    self.resumeValue = resumeValue
  }

  public static func resume<Value: Codable & Sendable>(_ value: Value) throws -> Self {
    CoreAgentGraphCommand(resumeValue: try CoreAgentGraphResumeValue(value))
  }
}

public struct CoreAgentGraphCustomEvent: Equatable, Sendable {
  public let name: String
  public let value: CoreAgentGraphResumeValue

  public init<Value: Codable & Sendable>(
    name: String,
    value: Value
  ) throws {
    self.name = name
    self.value = try CoreAgentGraphResumeValue(value)
  }
}

public struct CoreAgentGraphInterrupt: Error, Equatable, Sendable {
  public let id: CoreAgentGraphInterruptID
  public let value: CoreAgentGraphResumeValue

  public init<Value: Codable & Sendable>(
    id: CoreAgentGraphInterruptID = .make(),
    value: Value
  ) throws {
    self.id = id
    self.value = try CoreAgentGraphResumeValue(value)
  }
}
