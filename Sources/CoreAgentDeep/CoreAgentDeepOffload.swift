import Foundation
import FoundationModels

public struct CoreAgentDeepToolResultOffloadConfiguration: Codable, Equatable, Sendable {
  public let maximumInlineCharacters: Int
  public let previewCharacters: Int
  public let pathPrefix: String
  public let excludedToolNames: Set<String>

  public init(
    maximumInlineCharacters: Int = Self.defaultMaximumInlineCharacters,
    previewCharacters: Int = 2_000,
    pathPrefix: String = "/large_tool_results",
    excludedToolNames: Set<String> = Self.defaultExcludedToolNames
  ) {
    self.maximumInlineCharacters = maximumInlineCharacters
    self.previewCharacters = previewCharacters
    self.pathPrefix = pathPrefix
    self.excludedToolNames = excludedToolNames
  }

  public var approximateTokenLimit: Int {
    maximumInlineCharacters / Self.approximateCharactersPerToken
  }

  public static let defaultToolTokenLimitBeforeOffload = 20_000
  public static let approximateCharactersPerToken = 4
  public static let defaultMaximumInlineCharacters =
    defaultToolTokenLimitBeforeOffload * approximateCharactersPerToken
  public static let defaultExcludedToolNames: Set<String> = [
    "ls",
    "glob",
    "grep",
    "read_file",
    "edit_file",
    "write_file",
    "delete",
    "delete_file",
    "write_todos",
  ]
}

public struct CoreAgentDeepToolResultOffload: Codable, Equatable, Sendable {
  public let path: String
  public let originalCharacterCount: Int
  public let preview: String
  public let message: String

  public init(
    path: String,
    originalCharacterCount: Int,
    preview: String,
    message: String
  ) {
    self.path = path
    self.originalCharacterCount = originalCharacterCount
    self.preview = preview
    self.message = message
  }
}

public enum CoreAgentDeepToolResultOffloadDecision: Equatable, Sendable {
  case inline(String)
  case offloaded(CoreAgentDeepToolResultOffload)

  public var offloadedPath: String? {
    guard case .offloaded(let offload) = self else { return nil }
    return offload.path
  }

  public var offloadMessage: String? {
    guard case .offloaded(let offload) = self else { return nil }
    return offload.message
  }
}

public struct CoreAgentDeepToolResultOffloader: Sendable {
  private let filesystem: any CoreAgentDeepFilesystemBackend
  private let configuration: CoreAgentDeepToolResultOffloadConfiguration

  public init(
    filesystem: any CoreAgentDeepFilesystemBackend,
    configuration: CoreAgentDeepToolResultOffloadConfiguration
  ) {
    self.filesystem = filesystem
    self.configuration = configuration
  }

  public func process(
    toolName: String,
    toolCallID: String,
    content: String
  ) async throws -> CoreAgentDeepToolResultOffloadDecision {
    guard !configuration.excludedToolNames.contains(toolName) else {
      return .inline(content)
    }
    guard content.count > configuration.maximumInlineCharacters else {
      return .inline(content)
    }

    let path = offloadPath(for: toolCallID)
    try await filesystem.writeFile(content, at: path)
    let preview = preview(for: content)
    let offload = CoreAgentDeepToolResultOffload(
      path: path,
      originalCharacterCount: content.count,
      preview: preview,
      message: offloadMessage(path: path, characterCount: content.count, preview: preview)
    )
    return .offloaded(offload)
  }

  private func offloadPath(for toolCallID: String) -> String {
    let prefix = normalizedPathPrefix(configuration.pathPrefix)
    return "\(prefix)/\(sanitizedToolCallID(toolCallID))"
  }

  private func normalizedPathPrefix(_ prefix: String) -> String {
    let prefixed = prefix.hasPrefix("/") ? prefix : "/" + prefix
    guard prefixed.count > 1, prefixed.hasSuffix("/") else {
      return prefixed
    }
    return String(prefixed.dropLast())
  }

  private func sanitizedToolCallID(_ toolCallID: String) -> String {
    let scalars = toolCallID.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar)
        || scalar == "-"
        || scalar == "_"
      {
        return Character(scalar)
      }
      return "_"
    }
    let sanitized = String(scalars)
    return sanitized.isEmpty ? "unknown_tool_call" : sanitized
  }

  private func preview(for content: String) -> String {
    guard configuration.previewCharacters > 0 else { return "" }
    guard content.count > configuration.previewCharacters * 2 else {
      return content
    }
    let headEnd = content.index(
      content.startIndex,
      offsetBy: configuration.previewCharacters
    )
    let tailStart = content.index(
      content.endIndex,
      offsetBy: -configuration.previewCharacters
    )
    return "\(content[..<headEnd])\n...\n\(content[tailStart...])"
  }

  private func offloadMessage(path: String, characterCount: Int, preview: String) -> String {
    """
    COREAGENT_DEEP_TOOL_RESULT_OFFLOADED_V1 path=\(path) characters=\(characterCount)
    Use read_file with pagination to inspect the full content, or grep under /large_tool_results if the exact path is unknown.

    Preview:
    \(preview)
    """
  }
}

public enum CoreAgentDeepToolResultSerializationError: Error, Equatable, Sendable {
  case encodingFailed
}

public enum CoreAgentDeepToolResultSerialization {
  public static func jsonString<Value: Encodable & Sendable>(
    from value: Value
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw CoreAgentDeepToolResultSerializationError.encodingFailed
    }
    return string
  }
}

public enum CoreAgentDeepToolOffloading {
  public static func wrapString<Base: Tool>(
    _ tool: Base,
    offloader: CoreAgentDeepToolResultOffloader,
    toolCallID: @escaping @Sendable () async -> String
  ) -> CoreAgentDeepOffloadingTool<Base> where Base.Output == String {
    CoreAgentDeepOffloadingTool(
      tool: tool,
      offloader: offloader,
      toolCallID: toolCallID
    )
  }

  public static func wrapEncodable<Base: Tool>(
    _ tool: Base,
    offloader: CoreAgentDeepToolResultOffloader,
    toolCallID: @escaping @Sendable () async -> String
  ) -> CoreAgentDeepOffloadingEncodableTool<Base>
  where Base.Output: Encodable & Sendable {
    CoreAgentDeepOffloadingEncodableTool(
      tool: tool,
      offloader: offloader,
      toolCallID: toolCallID
    )
  }
}

public struct CoreAgentDeepOffloadingEncodableTool<Base: Tool>: Tool
where Base.Output: Encodable & Sendable {
  public typealias Arguments = Base.Arguments
  public typealias Output = String

  private let tool: Base
  private let offloader: CoreAgentDeepToolResultOffloader
  private let toolCallID: @Sendable () async -> String

  public var name: String { tool.name }
  public var description: String { tool.description }
  public var parameters: GenerationSchema { tool.parameters }
  public var includesSchemaInInstructions: Bool { tool.includesSchemaInInstructions }

  public init(
    tool: Base,
    offloader: CoreAgentDeepToolResultOffloader,
    toolCallID: @escaping @Sendable () async -> String
  ) {
    self.tool = tool
    self.offloader = offloader
    self.toolCallID = toolCallID
  }

  @concurrent
  public func call(arguments: Base.Arguments) async throws -> String {
    let output = try await tool.call(arguments: arguments)
    let serialized = try CoreAgentDeepToolResultSerialization.jsonString(from: output)
    let decision = try await offloader.process(
      toolName: tool.name,
      toolCallID: toolCallID(),
      content: serialized
    )
    switch decision {
    case .inline(let content):
      return content
    case .offloaded(let offload):
      return offload.message
    }
  }
}

public struct CoreAgentDeepOffloadingTool<Base: Tool>: Tool where Base.Output == String {
  public typealias Arguments = Base.Arguments
  public typealias Output = String

  private let tool: Base
  private let offloader: CoreAgentDeepToolResultOffloader
  private let toolCallID: @Sendable () async -> String

  public var name: String { tool.name }
  public var description: String { tool.description }
  public var parameters: GenerationSchema { tool.parameters }
  public var includesSchemaInInstructions: Bool { tool.includesSchemaInInstructions }

  public init(
    tool: Base,
    offloader: CoreAgentDeepToolResultOffloader,
    toolCallID: @escaping @Sendable () async -> String
  ) {
    self.tool = tool
    self.offloader = offloader
    self.toolCallID = toolCallID
  }

  @concurrent
  public func call(arguments: Base.Arguments) async throws -> String {
    let output = try await tool.call(arguments: arguments)
    let decision = try await offloader.process(
      toolName: tool.name,
      toolCallID: toolCallID(),
      content: output
    )
    switch decision {
    case .inline(let content):
      return content
    case .offloaded(let offload):
      return offload.message
    }
  }
}
