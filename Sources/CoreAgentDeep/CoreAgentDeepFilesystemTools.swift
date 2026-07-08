import FoundationModels

@Generable
public struct CoreAgentDeepReadFileArguments: Sendable {
  public let path: String

  public init(path: String) {
    self.path = path
  }
}

@Generable
public struct CoreAgentDeepWriteFileArguments: Sendable {
  public let path: String
  public let content: String

  public init(path: String, content: String) {
    self.path = path
    self.content = content
  }
}

@Generable
public struct CoreAgentDeepListDirectoryArguments: Sendable {
  public let path: String

  public init(path: String) {
    self.path = path
  }
}

@Generable
public struct CoreAgentDeepEditFileArguments: Sendable {
  public let path: String
  public let oldString: String
  public let newString: String
  public let replaceAll: Bool

  public init(path: String, oldString: String, newString: String, replaceAll: Bool = false) {
    self.path = path
    self.oldString = oldString
    self.newString = newString
    self.replaceAll = replaceAll
  }
}

@Generable
public struct CoreAgentDeepGlobArguments: Sendable {
  public let pattern: String
  public let path: String?

  public init(pattern: String, path: String? = nil) {
    self.pattern = pattern
    self.path = path
  }
}

@Generable
public struct CoreAgentDeepGrepArguments: Sendable {
  public let pattern: String
  public let path: String?
  public let glob: String?
  public let outputMode: String

  public init(
    pattern: String,
    path: String? = nil,
    glob: String? = nil,
    outputMode: String = CoreAgentDeepGrepOutputMode.filesWithMatches.rawValue
  ) {
    self.pattern = pattern
    self.path = path
    self.glob = glob
    self.outputMode = outputMode
  }

  public func typedOutputMode() throws -> CoreAgentDeepGrepOutputMode {
    guard let mode = CoreAgentDeepGrepOutputMode(rawValue: outputMode) else {
      throw CoreAgentDeepFilesystemError.invalidGrepOutputMode(outputMode)
    }
    return mode
  }
}

@Generable
public struct CoreAgentDeepDeleteFileArguments: Sendable {
  public let path: String

  public init(path: String) {
    self.path = path
  }
}

public struct CoreAgentDeepReadFileTool: Tool {
  public let name = "read_file"
  public let description = "Reads a UTF-8 text file from the governed CoreAgentDeep filesystem."

  private let filesystem: any CoreAgentDeepFilesystemBackend

  public init(filesystem: any CoreAgentDeepFilesystemBackend) {
    self.filesystem = filesystem
  }

  @concurrent
  public func call(arguments: CoreAgentDeepReadFileArguments) async throws -> String {
    try await filesystem.readFile(at: arguments.path)
  }
}

public struct CoreAgentDeepWriteFileTool: Tool {
  public let name = "write_file"
  public let description = "Writes a UTF-8 text file into the governed CoreAgentDeep filesystem."

  private let filesystem: any CoreAgentDeepFilesystemBackend

  public init(filesystem: any CoreAgentDeepFilesystemBackend) {
    self.filesystem = filesystem
  }

  @concurrent
  public func call(arguments: CoreAgentDeepWriteFileArguments) async throws -> String {
    try await filesystem.writeFile(arguments.content, at: arguments.path)
    return "COREAGENT_DEEP_FILE_WRITTEN_V1 path=\(arguments.path)"
  }
}

public struct CoreAgentDeepListDirectoryTool: Tool {
  public let name = "ls"
  public let description =
    "Lists files in a directory in the governed CoreAgentDeep filesystem."

  private let filesystem: any CoreAgentDeepFilesystemBackend

  public init(filesystem: any CoreAgentDeepFilesystemBackend) {
    self.filesystem = filesystem
  }

  @concurrent
  public func call(arguments: CoreAgentDeepListDirectoryArguments) async throws -> String {
    let files = try await filesystem.listDirectory(at: arguments.path)
    return files.map(\.path).joined(separator: "\n")
  }
}

public struct CoreAgentDeepEditFileTool: Tool {
  public let name = "edit_file"
  public let description =
    "Performs an exact string replacement in a UTF-8 text file in the governed CoreAgentDeep filesystem."

  private let filesystem: any CoreAgentDeepFilesystemBackend

  public init(filesystem: any CoreAgentDeepFilesystemBackend) {
    self.filesystem = filesystem
  }

  @concurrent
  public func call(arguments: CoreAgentDeepEditFileArguments) async throws -> String {
    let result = try await filesystem.editFile(
      at: arguments.path,
      replacing: arguments.oldString,
      with: arguments.newString,
      replaceAll: arguments.replaceAll
    )
    return "COREAGENT_DEEP_FILE_EDITED_V1 path=\(result.path) occurrences=\(result.occurrences)"
  }
}

public struct CoreAgentDeepGlobTool: Tool {
  public let name = "glob"
  public let description =
    "Finds files matching a glob pattern in the governed CoreAgentDeep filesystem."

  private let filesystem: any CoreAgentDeepFilesystemBackend

  public init(filesystem: any CoreAgentDeepFilesystemBackend) {
    self.filesystem = filesystem
  }

  @concurrent
  public func call(arguments: CoreAgentDeepGlobArguments) async throws -> String {
    let paths = try await filesystem.glob(pattern: arguments.pattern, path: arguments.path)
    return paths.joined(separator: "\n")
  }
}

public struct CoreAgentDeepGrepTool: Tool {
  public let name = "grep"
  public let description =
    "Searches for literal text across files in the governed CoreAgentDeep filesystem."

  private let filesystem: any CoreAgentDeepFilesystemBackend

  public init(filesystem: any CoreAgentDeepFilesystemBackend) {
    self.filesystem = filesystem
  }

  @concurrent
  public func call(arguments: CoreAgentDeepGrepArguments) async throws -> String {
    let matches = try await filesystem.grep(
      pattern: arguments.pattern,
      path: arguments.path,
      glob: arguments.glob
    )
    return format(matches: matches, mode: try arguments.typedOutputMode())
  }

  private func format(
    matches: [CoreAgentDeepGrepMatch],
    mode: CoreAgentDeepGrepOutputMode
  ) -> String {
    switch mode {
    case .filesWithMatches:
      return orderedPaths(from: matches).joined(separator: "\n")
    case .count:
      let counts = Dictionary(grouping: matches, by: \.path)
      return orderedPaths(from: matches)
        .map { path in "\(path): \(counts[path]?.count ?? 0)" }
        .joined(separator: "\n")
    case .content:
      return Dictionary(grouping: matches, by: \.path)
        .keys
        .sorted()
        .map { path in
          let lines =
            matches
            .filter { $0.path == path }
            .map { "  \($0.lineNumber): \($0.line)" }
            .joined(separator: "\n")
          return "\(path):\n\(lines)"
        }
        .joined(separator: "\n")
    }
  }

  private func orderedPaths(from matches: [CoreAgentDeepGrepMatch]) -> [String] {
    var seen: Set<String> = []
    var paths: [String] = []
    for match in matches where !seen.contains(match.path) {
      seen.insert(match.path)
      paths.append(match.path)
    }
    return paths
  }
}

public struct CoreAgentDeepDeleteTool: Tool {
  public let name = "delete"
  public let description = "Deletes a file from the governed CoreAgentDeep filesystem."

  private let filesystem: any CoreAgentDeepFilesystemBackend

  public init(filesystem: any CoreAgentDeepFilesystemBackend) {
    self.filesystem = filesystem
  }

  @concurrent
  public func call(arguments: CoreAgentDeepDeleteFileArguments) async throws -> String {
    try await filesystem.deleteFile(at: arguments.path)
    return "COREAGENT_DEEP_FILE_DELETED_V1 path=\(arguments.path)"
  }
}

public struct CoreAgentDeepDeleteFileTool: Tool {
  public let name = "delete_file"
  public let description =
    "Compatibility alias for delete. New model-facing surfaces should expose delete."

  private let tool: CoreAgentDeepDeleteTool

  public init(filesystem: any CoreAgentDeepFilesystemBackend) {
    self.tool = CoreAgentDeepDeleteTool(filesystem: filesystem)
  }

  @concurrent
  public func call(arguments: CoreAgentDeepDeleteFileArguments) async throws -> String {
    try await tool.call(arguments: arguments)
  }
}
