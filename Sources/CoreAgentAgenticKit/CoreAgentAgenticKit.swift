import CoreAgent
import CoreAgentDeep
import CoreAgentEngine
import CoreAgentGraph
import CoreAgentSkills
import FoundationModels

public struct CoreAgentAgenticKitConfiguration: Sendable, Equatable {
  public let projectID: String
  public let threadID: String?
  public let filesystemToolSurface: CoreAgentDeepFilesystemToolSurface
  public let filesystemToolCapabilities: CoreAgentDeepFilesystemToolCapabilities
  public let filesystemPermissions: [CoreAgentDeepFilesystemPermissionRule]
  public let initialFilesystemFiles: [String: String]

  public init(
    projectID: String,
    threadID: String? = nil,
    filesystemToolSurface: CoreAgentDeepFilesystemToolSurface = .all,
    filesystemToolCapabilities: CoreAgentDeepFilesystemToolCapabilities = .all,
    filesystemPermissions: [CoreAgentDeepFilesystemPermissionRule] = [
      .allow(
        operations: [.read, .write, .list, .edit, .glob, .grep, .delete],
        paths: ["/**"]
      )
    ],
    initialFilesystemFiles: [String: String] = [:]
  ) {
    self.projectID = projectID
    self.threadID = threadID
    self.filesystemToolSurface = filesystemToolSurface
    self.filesystemToolCapabilities = filesystemToolCapabilities
    self.filesystemPermissions = filesystemPermissions
    self.initialFilesystemFiles = initialFilesystemFiles
  }
}

public struct CoreAgentAgenticKit: Sendable {
  public let configuration: CoreAgentAgenticKitConfiguration
  public let filesystem: CoreAgentDeepStateFilesystem
  public let todoStore: CoreAgentDeepTodoStore
  public let engineStore: InMemoryCoreAgentEngineStore
  public let subagentAuditStore: CoreAgentDeepSubagentAuditStore

  public init(configuration: CoreAgentAgenticKitConfiguration) {
    self.configuration = configuration
    self.filesystem = CoreAgentDeepStateFilesystem(
      files: configuration.initialFilesystemFiles,
      permissions: configuration.filesystemPermissions
    )
    self.todoStore = CoreAgentDeepTodoStore()
    self.engineStore = InMemoryCoreAgentEngineStore()
    self.subagentAuditStore = CoreAgentDeepSubagentAuditStore()
  }

  public func filesystemTools() -> [any Tool] {
    configuration.filesystemToolSurface.makeTools(
      filesystem: filesystem,
      capabilities: configuration.filesystemToolCapabilities
    )
  }

  public func makePlugins(subagents: [any CoreAgentDeepSubagent] = []) throws
    -> [any CoreAgentSessionPlugin]
  {
    [
      CoreAgentDeepTodosPlugin(store: todoStore),
      try CoreAgentDeepSubagentsPlugin(
        subagents: subagents,
        auditStore: subagentAuditStore
      ),
      CoreAgentEnginePlugin(
        store: engineStore,
        projectID: configuration.projectID,
        threadID: configuration.threadID
      ),
    ]
  }

  public func makeSession<Model: LanguageModel>(
    model: Model,
    subagents: [any CoreAgentDeepSubagent] = [],
    instructions: Instructions? = nil,
    toolConfiguration: CoreAgentToolConfiguration = .init(policy: AllowAllCoreAgentToolPolicy())
  ) throws -> CoreAgentSession {
    try CoreAgentSession(
      model: model,
      tools: filesystemTools(),
      instructions: instructions,
      toolConfiguration: toolConfiguration,
      plugins: try makePlugins(subagents: subagents)
    )
  }
}

public typealias CoreAgentAgenticGraphNodeID = CoreAgentGraphNodeID
