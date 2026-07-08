import FoundationModels

public enum CoreAgentDeepFilesystemToolName:
  String, Codable, CaseIterable, Equatable, Hashable, Sendable
{
  case list = "ls"
  case readFile = "read_file"
  case writeFile = "write_file"
  case editFile = "edit_file"
  case delete = "delete"
  case glob
  case grep

  public static let modelFacingOrder: [Self] = [
    .list,
    .readFile,
    .writeFile,
    .editFile,
    .delete,
    .glob,
    .grep,
  ]
}

public enum CoreAgentDeepFilesystemToolSurfaceError: Error, Equatable, Sendable {
  case missingRequiredReadFile
}

public struct CoreAgentDeepFilesystemToolCapabilities: Codable, Equatable, Sendable {
  public let supportedToolNames: Set<CoreAgentDeepFilesystemToolName>

  public init(
    supporting supportedToolNames: Set<CoreAgentDeepFilesystemToolName> = Set(
      CoreAgentDeepFilesystemToolName.allCases
    )
  ) throws {
    guard supportedToolNames.contains(.readFile) else {
      throw CoreAgentDeepFilesystemToolSurfaceError.missingRequiredReadFile
    }
    self.supportedToolNames = supportedToolNames
  }

  private init(unchecked supportedToolNames: Set<CoreAgentDeepFilesystemToolName>) {
    self.supportedToolNames = supportedToolNames
  }

  public static let all = CoreAgentDeepFilesystemToolCapabilities(
    unchecked: Set(CoreAgentDeepFilesystemToolName.allCases)
  )
}

public struct CoreAgentDeepFilesystemToolSurface: Codable, Equatable, Sendable {
  public let allowedToolNames: Set<CoreAgentDeepFilesystemToolName>

  public init(
    allowing allowedToolNames: Set<CoreAgentDeepFilesystemToolName> = Set(
      CoreAgentDeepFilesystemToolName.allCases
    )
  ) throws {
    guard allowedToolNames.contains(.readFile) else {
      throw CoreAgentDeepFilesystemToolSurfaceError.missingRequiredReadFile
    }
    self.allowedToolNames = allowedToolNames
  }

  public init(excluding excludedToolNames: Set<CoreAgentDeepFilesystemToolName>) throws {
    try self.init(
      allowing: Set(CoreAgentDeepFilesystemToolName.allCases).subtracting(excludedToolNames)
    )
  }

  private init(unchecked allowedToolNames: Set<CoreAgentDeepFilesystemToolName>) {
    self.allowedToolNames = allowedToolNames
  }

  public static let all = CoreAgentDeepFilesystemToolSurface(
    unchecked: Set(CoreAgentDeepFilesystemToolName.allCases)
  )

  public static let readOnly = CoreAgentDeepFilesystemToolSurface(
    unchecked: [.list, .readFile, .glob, .grep]
  )

  public func makeTools(
    filesystem: any CoreAgentDeepFilesystemBackend,
    capabilities: CoreAgentDeepFilesystemToolCapabilities = .all
  ) -> [any Tool] {
    CoreAgentDeepFilesystemToolName.modelFacingOrder.compactMap { toolName in
      guard allowedToolNames.contains(toolName),
        capabilities.supportedToolNames.contains(toolName)
      else { return nil }
      return Self.makeTool(named: toolName, filesystem: filesystem)
    }
  }

  private static func makeTool(
    named toolName: CoreAgentDeepFilesystemToolName,
    filesystem: any CoreAgentDeepFilesystemBackend
  ) -> (any Tool) {
    switch toolName {
    case .list:
      CoreAgentDeepListDirectoryTool(filesystem: filesystem)
    case .readFile:
      CoreAgentDeepReadFileTool(filesystem: filesystem)
    case .writeFile:
      CoreAgentDeepWriteFileTool(filesystem: filesystem)
    case .editFile:
      CoreAgentDeepEditFileTool(filesystem: filesystem)
    case .delete:
      CoreAgentDeepDeleteTool(filesystem: filesystem)
    case .glob:
      CoreAgentDeepGlobTool(filesystem: filesystem)
    case .grep:
      CoreAgentDeepGrepTool(filesystem: filesystem)
    }
  }
}
