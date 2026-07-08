import CoreAgentDeep
import Foundation
import Testing

@Suite("CoreAgentDeep filesystem")
struct CoreAgentDeepFilesystemTests {
  @Test("Denies file operations by default")
  func deniesByDefault() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let filesystem = CoreAgentDeepLocalFilesystem(rootDirectory: root)

    await #expect(
      throws: CoreAgentDeepFilesystemError.denied(
        operation: .read,
        path: "/notes.txt"
      )
    ) {
      _ = try await filesystem.readFile(at: "/notes.txt")
    }
  }

  @Test("Allows read write list and delete only when explicit rules match")
  func allowsExplicitOperations() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let filesystem = CoreAgentDeepLocalFilesystem(
      rootDirectory: root,
      permissions: [
        .allow(operations: [.read, .write, .list, .delete], paths: ["/workspace/**"])
      ]
    )

    try await filesystem.writeFile("hello", at: "/workspace/notes.txt")

    #expect(try await filesystem.readFile(at: "/workspace/notes.txt") == "hello")
    #expect(
      try await filesystem.listDirectory(at: "/workspace").map(\.path) == [
        "/workspace/notes.txt"
      ])
    try await filesystem.deleteFile(at: "/workspace/notes.txt")
    #expect(try await filesystem.listDirectory(at: "/workspace").isEmpty)
  }

  @Test("Applies first matching permission rule")
  func appliesFirstMatchWins() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let filesystem = CoreAgentDeepLocalFilesystem(
      rootDirectory: root,
      permissions: [
        .deny(operations: [.write], paths: ["/workspace/private/**"]),
        .allow(operations: [.write], paths: ["/workspace/**"]),
      ]
    )

    await #expect(
      throws: CoreAgentDeepFilesystemError.denied(
        operation: .write,
        path: "/workspace/private/secret.txt"
      )
    ) {
      try await filesystem.writeFile("secret", at: "/workspace/private/secret.txt")
    }
    try await filesystem.writeFile("public", at: "/workspace/public.txt")
  }

  @Test("Rejects parent directory and symlink escapes before permissions")
  func rejectsEscapesBeforePermissions() async throws {
    let root = try makeTemporaryDirectory()
    let outside = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let outsideFile = outside.appending(path: "secret.txt")
    try "secret".write(to: outsideFile, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "escape"),
      withDestinationURL: outside
    )
    let filesystem = CoreAgentDeepLocalFilesystem(
      rootDirectory: root,
      permissions: [.allow(operations: [.read], paths: ["/**"])]
    )

    await #expect(throws: CoreAgentDeepFilesystemError.escapedRoot(path: "/../secret.txt")) {
      _ = try await filesystem.readFile(at: "/../secret.txt")
    }
    await #expect(throws: CoreAgentDeepFilesystemError.escapedRoot(path: "/escape/secret.txt")) {
      _ = try await filesystem.readFile(at: "/escape/secret.txt")
    }
    #expect(
      await filesystem.auditEvents() == [
        CoreAgentDeepFilesystemAuditEvent(
          operation: .read,
          path: "/../secret.txt",
          decision: .denied
        ),
        CoreAgentDeepFilesystemAuditEvent(
          operation: .read,
          path: "/escape/secret.txt",
          decision: .denied
        ),
      ])
  }

  @Test("Rejects home directory shorthand as a host path escape")
  func rejectsHomeDirectoryShorthand() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.read], paths: ["/**"])]
    )

    await #expect(throws: CoreAgentDeepFilesystemError.escapedRoot(path: "/~/secret.txt")) {
      _ = try await filesystem.readFile(at: "~/secret.txt")
    }
    #expect(
      await filesystem.auditEvents() == [
        CoreAgentDeepFilesystemAuditEvent(
          operation: .read,
          path: "/~/secret.txt",
          decision: .denied
        )
      ])
  }

  @Test("Records denied operations as audit-visible events")
  func recordsDeniedOperations() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let filesystem = CoreAgentDeepLocalFilesystem(rootDirectory: root)

    await #expect(
      throws: CoreAgentDeepFilesystemError.denied(
        operation: .write,
        path: "/notes.txt"
      )
    ) {
      try await filesystem.writeFile("blocked", at: "/notes.txt")
    }

    #expect(await filesystem.auditEvents().map(\.decision) == [.denied])
  }

  @Test("Exposes filesystem tools with Deep Agents compatible names")
  func exposesFilesystemToolNames() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let filesystem = CoreAgentDeepLocalFilesystem(rootDirectory: root)

    #expect(CoreAgentDeepReadFileTool(filesystem: filesystem).name == "read_file")
    #expect(CoreAgentDeepWriteFileTool(filesystem: filesystem).name == "write_file")
    #expect(CoreAgentDeepListDirectoryTool(filesystem: filesystem).name == "ls")
    #expect(CoreAgentDeepEditFileTool(filesystem: filesystem).name == "edit_file")
    #expect(CoreAgentDeepGlobTool(filesystem: filesystem).name == "glob")
    #expect(CoreAgentDeepGrepTool(filesystem: filesystem).name == "grep")
    #expect(CoreAgentDeepDeleteTool(filesystem: filesystem).name == "delete")
    #expect(CoreAgentDeepDeleteFileTool(filesystem: filesystem).name == "delete_file")
  }

  @Test("Default filesystem tool surface uses current Deep Agents delete name")
  func defaultFilesystemToolSurfaceUsesCurrentDeleteName() async throws {
    let filesystem = CoreAgentDeepStateFilesystem()

    #expect(
      CoreAgentDeepFilesystemToolSurface.all.makeTools(filesystem: filesystem).map(\.name) == [
        "ls",
        "read_file",
        "write_file",
        "edit_file",
        "delete",
        "glob",
        "grep",
      ])
  }

  @Test("Filesystem tool allowlist requires read_file")
  func filesystemToolAllowlistRequiresReadFile() throws {
    #expect(throws: CoreAgentDeepFilesystemToolSurfaceError.missingRequiredReadFile) {
      _ = try CoreAgentDeepFilesystemToolSurface(allowing: [.list, .glob, .grep])
    }
  }

  @Test("Filesystem tool allowlist removes omitted built-ins without adding aliases")
  func filesystemToolAllowlistRemovesOmittedBuiltIns() async throws {
    let filesystem = CoreAgentDeepStateFilesystem()
    let surface = try CoreAgentDeepFilesystemToolSurface(
      allowing: [.readFile, .list, .glob, .grep]
    )

    #expect(
      surface.makeTools(filesystem: filesystem).map(\.name) == [
        "ls",
        "read_file",
        "glob",
        "grep",
      ])
  }

  @Test("Filesystem tool exclusions hide only built-in filesystem tools")
  func filesystemToolExclusionsHideBuiltIns() async throws {
    let filesystem = CoreAgentDeepStateFilesystem()
    let surface = try CoreAgentDeepFilesystemToolSurface(excluding: [.writeFile, .delete])

    #expect(
      surface.makeTools(filesystem: filesystem).map(\.name) == [
        "ls",
        "read_file",
        "edit_file",
        "glob",
        "grep",
      ])
  }

  @Test("Filesystem tool exclusions cannot remove read_file")
  func filesystemToolExclusionsCannotRemoveReadFile() throws {
    #expect(throws: CoreAgentDeepFilesystemToolSurfaceError.missingRequiredReadFile) {
      _ = try CoreAgentDeepFilesystemToolSurface(excluding: [.readFile])
    }
  }

  @Test("Filesystem capabilities require read_file support")
  func filesystemCapabilitiesRequireReadFileSupport() throws {
    #expect(throws: CoreAgentDeepFilesystemToolSurfaceError.missingRequiredReadFile) {
      _ = try CoreAgentDeepFilesystemToolCapabilities(supporting: [.list, .glob, .grep])
    }
  }

  @Test("Filesystem tool surface hides unsupported delete capability")
  func filesystemToolSurfaceHidesUnsupportedDeleteCapability() async throws {
    let filesystem = CoreAgentDeepStateFilesystem()
    let capabilities = try CoreAgentDeepFilesystemToolCapabilities(
      supporting: [.list, .readFile, .writeFile, .editFile, .glob, .grep]
    )

    #expect(
      CoreAgentDeepFilesystemToolSurface.all
        .makeTools(filesystem: filesystem, capabilities: capabilities)
        .map(\.name) == [
          "ls",
          "read_file",
          "write_file",
          "edit_file",
          "glob",
          "grep",
        ]
    )
  }

  @Test("Filesystem tools call through the governed backend")
  func filesystemToolsCallBackend() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let filesystem = CoreAgentDeepLocalFilesystem(
      rootDirectory: root,
      permissions: [
        .allow(operations: [.read, .write, .list, .delete], paths: ["/workspace/**"])
      ]
    )
    let writer = CoreAgentDeepWriteFileTool(filesystem: filesystem)
    let reader = CoreAgentDeepReadFileTool(filesystem: filesystem)
    let lister = CoreAgentDeepListDirectoryTool(filesystem: filesystem)
    let deleter = CoreAgentDeepDeleteTool(filesystem: filesystem)

    #expect(
      try await writer.call(
        arguments: CoreAgentDeepWriteFileArguments(
          path: "/workspace/report.md",
          content: "draft"
        )
      ) == "COREAGENT_DEEP_FILE_WRITTEN_V1 path=/workspace/report.md"
    )
    #expect(
      try await reader.call(arguments: CoreAgentDeepReadFileArguments(path: "/workspace/report.md"))
        == "draft"
    )
    #expect(
      try await lister.call(arguments: CoreAgentDeepListDirectoryArguments(path: "/workspace"))
        == "/workspace/report.md"
    )
    #expect(
      try await deleter.call(
        arguments: CoreAgentDeepDeleteFileArguments(path: "/workspace/report.md"))
        == "COREAGENT_DEEP_FILE_DELETED_V1 path=/workspace/report.md"
    )
  }

  @Test("edit_file replaces one unique string and rejects ambiguous edits")
  func editFileReplacesUniqueString() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [
        .allow(operations: [.read, .write, .edit], paths: ["/workspace/**"])
      ]
    )
    try await filesystem.writeFile("hello world", at: "/workspace/report.md")
    let editor = CoreAgentDeepEditFileTool(filesystem: filesystem)

    #expect(
      try await editor.call(
        arguments: CoreAgentDeepEditFileArguments(
          path: "/workspace/report.md",
          oldString: "world",
          newString: "CoreAgent",
          replaceAll: false
        )
      ) == "COREAGENT_DEEP_FILE_EDITED_V1 path=/workspace/report.md occurrences=1"
    )
    #expect(try await filesystem.readFile(at: "/workspace/report.md") == "hello CoreAgent")

    try await filesystem.writeFile("token token", at: "/workspace/ambiguous.md")
    await #expect(
      throws: CoreAgentDeepFilesystemError.editTargetNotUnique(
        path: "/workspace/ambiguous.md",
        occurrences: 2
      )
    ) {
      _ = try await editor.call(
        arguments: CoreAgentDeepEditFileArguments(
          path: "/workspace/ambiguous.md",
          oldString: "token",
          newString: "value",
          replaceAll: false
        )
      )
    }
  }

  @Test("Read and write grants do not implicitly authorize bulk or edit tools")
  func readAndWriteDoNotImplicitlyAuthorizeOtherOperations() async throws {
    let readOnlyFilesystem = CoreAgentDeepStateFilesystem(
      files: [
        "/workspace/report.md": "needle\n"
      ],
      permissions: [
        .allow(operations: [.read], paths: ["/workspace/**"])
      ]
    )

    #expect(try await readOnlyFilesystem.readFile(at: "/workspace/report.md") == "needle\n")
    await #expect(
      throws: CoreAgentDeepFilesystemError.denied(
        operation: .list,
        path: "/workspace"
      )
    ) {
      _ = try await readOnlyFilesystem.listDirectory(at: "/workspace")
    }
    await #expect(
      throws: CoreAgentDeepFilesystemError.denied(
        operation: .glob,
        path: "/workspace"
      )
    ) {
      _ = try await readOnlyFilesystem.glob(pattern: "**/*.md", path: "/workspace")
    }
    await #expect(
      throws: CoreAgentDeepFilesystemError.denied(
        operation: .grep,
        path: "/workspace"
      )
    ) {
      _ = try await readOnlyFilesystem.grep(pattern: "needle", path: "/workspace", glob: nil)
    }

    let writeOnlyFilesystem = CoreAgentDeepStateFilesystem(
      files: [
        "/workspace/report.md": "needle\n"
      ],
      permissions: [
        .allow(operations: [.write], paths: ["/workspace/**"])
      ]
    )
    await #expect(
      throws: CoreAgentDeepFilesystemError.denied(
        operation: .edit,
        path: "/workspace/report.md"
      )
    ) {
      _ = try await writeOnlyFilesystem.editFile(
        at: "/workspace/report.md",
        replacing: "needle",
        with: "value",
        replaceAll: false
      )
    }
  }

  @Test("glob and grep return only permission-visible files")
  func globAndGrepFilterDeniedMatches() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      files: [
        "/workspace/Public.swift": "let needle = true\n",
        "/workspace/private/Secret.swift": "let needle = false\n",
        "/workspace/notes.txt": "needle\n",
      ],
      permissions: [
        .deny(operations: [.glob, .grep], paths: ["/workspace/private/**"]),
        .allow(operations: [.glob, .grep], paths: ["/workspace/**"]),
      ]
    )
    let glob = CoreAgentDeepGlobTool(filesystem: filesystem)
    let grep = CoreAgentDeepGrepTool(filesystem: filesystem)

    #expect(
      try await glob.call(
        arguments: CoreAgentDeepGlobArguments(pattern: "**/*.swift", path: "/workspace")
      ) == "/workspace/Public.swift"
    )
    #expect(
      try await grep.call(
        arguments: CoreAgentDeepGrepArguments(
          pattern: "needle",
          path: "/workspace",
          glob: "*.swift",
          outputMode: "files_with_matches"
        )
      ) == "/workspace/Public.swift"
    )
    #expect(
      try await grep.call(
        arguments: CoreAgentDeepGrepArguments(
          pattern: "needle",
          path: "/workspace",
          glob: "*.swift",
          outputMode: "count"
        )
      ) == "/workspace/Public.swift: 1"
    )
  }

  @Test("grep content output includes line numbers for matched lines")
  func grepContentIncludesLineNumbers() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      files: [
        "/workspace/report.md": "first\nneedle line\nlast\n"
      ],
      permissions: [
        .allow(operations: [.grep], paths: ["/workspace/**"])
      ]
    )
    let grep = CoreAgentDeepGrepTool(filesystem: filesystem)

    #expect(
      try await grep.call(
        arguments: CoreAgentDeepGrepArguments(
          pattern: "needle",
          path: "/workspace",
          glob: "*.md",
          outputMode: "content"
        )
      ) == """
        /workspace/report.md:
          2: needle line
        """
    )
  }

  @Test("State filesystem is thread scoped and does not touch host disk")
  func stateFilesystemIsThreadScoped() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [
        .allow(operations: [.read, .write, .list, .delete], paths: ["/workspace/**"])
      ]
    )
    let writer = CoreAgentDeepWriteFileTool(filesystem: filesystem)
    let reader = CoreAgentDeepReadFileTool(filesystem: filesystem)

    _ = try await writer.call(
      arguments: CoreAgentDeepWriteFileArguments(path: "/workspace/note.txt", content: "state")
    )

    #expect(
      try await reader.call(arguments: CoreAgentDeepReadFileArguments(path: "/workspace/note.txt"))
        == "state"
    )
    #expect(await filesystem.snapshot() == ["/workspace/note.txt": "state"])
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
