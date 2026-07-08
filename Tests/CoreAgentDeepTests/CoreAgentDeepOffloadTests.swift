import CoreAgentDeep
import FoundationModels
import Testing

@Suite("CoreAgentDeep large result offload")
struct CoreAgentDeepOffloadTests {
  @Test("Keeps small tool results inline")
  func keepsSmallResultsInline() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write], paths: ["/large_tool_results/**"])]
    )
    let offloader = CoreAgentDeepToolResultOffloader(
      filesystem: filesystem,
      configuration: .init(maximumInlineCharacters: 20)
    )

    let result = try await offloader.process(
      toolName: "custom_tool",
      toolCallID: "call-1",
      content: "small"
    )

    #expect(result == .inline("small"))
    #expect(await filesystem.snapshot().isEmpty)
  }

  @Test("Offloads large non-excluded tool results to deterministic filesystem paths")
  func offloadsLargeResults() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .read], paths: ["/large_tool_results/**"])]
    )
    let offloader = CoreAgentDeepToolResultOffloader(
      filesystem: filesystem,
      configuration: .init(maximumInlineCharacters: 12, previewCharacters: 4)
    )

    let result = try await offloader.process(
      toolName: "custom_tool",
      toolCallID: "call-123",
      content: "abcdefghijklmnopqrstuvwxyz"
    )

    #expect(
      result
        == .offloaded(
          CoreAgentDeepToolResultOffload(
            path: "/large_tool_results/call-123",
            originalCharacterCount: 26,
            preview: "abcd\n...\nwxyz",
            message: result.offloadMessage ?? ""
          )))
    #expect(result.offloadMessage?.contains("/large_tool_results/call-123") == true)
    #expect(result.offloadMessage?.contains("read_file") == true)
    #expect(result.offloadMessage?.contains("grep") == true)
    #expect(result.offloadMessage?.contains("abcd") == true)
    #expect(result.offloadMessage?.contains("wxyz") == true)
    #expect(
      try await filesystem.readFile(at: "/large_tool_results/call-123")
        == "abcdefghijklmnopqrstuvwxyz")
  }

  @Test("Does not offload built-in filesystem and todo tool results")
  func skipsExcludedBuiltInTools() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write], paths: ["/large_tool_results/**"])]
    )
    let offloader = CoreAgentDeepToolResultOffloader(
      filesystem: filesystem,
      configuration: .init(maximumInlineCharacters: 4)
    )
    let large = String(repeating: "x", count: 100)

    for toolName in [
      "ls",
      "glob",
      "grep",
      "read_file",
      "edit_file",
      "write_file",
      "delete",
      "delete_file",
      "write_todos",
    ] {
      #expect(
        try await offloader.process(
          toolName: toolName, toolCallID: "call-\(toolName)", content: large)
          == .inline(large)
      )
    }
    #expect(await filesystem.snapshot().isEmpty)
  }

  @Test("Sanitizes tool call IDs before using them as paths")
  func sanitizesToolCallIDPaths() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .read], paths: ["/large_tool_results/**"])]
    )
    let offloader = CoreAgentDeepToolResultOffloader(
      filesystem: filesystem,
      configuration: .init(maximumInlineCharacters: 1, previewCharacters: 3)
    )

    let result = try await offloader.process(
      toolName: "custom_tool",
      toolCallID: "../call with spaces",
      content: "abcdef"
    )

    #expect(result.offloadedPath == "/large_tool_results/___call_with_spaces")
    #expect(
      try await filesystem.readFile(at: "/large_tool_results/___call_with_spaces") == "abcdef")
  }

  @Test("Uses Deep Agents compatible default token threshold")
  func usesDefaultTokenThreshold() {
    let configuration = CoreAgentDeepToolResultOffloadConfiguration()

    #expect(configuration.maximumInlineCharacters == 80_000)
    #expect(configuration.approximateTokenLimit == 20_000)
  }

  @Test("Offloading wrapper preserves tool identity and offloads large string output")
  func wrapperOffloadsLargeStringOutput() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .read], paths: ["/large_tool_results/**"])]
    )
    let tool = CoreAgentDeepOffloadingTool(
      tool: StaticStringTool(
        name: "expensive_search",
        description: "Returns search output.",
        output: "abcdefghijklmnopqrstuvwxyz"
      ),
      offloader: CoreAgentDeepToolResultOffloader(
        filesystem: filesystem,
        configuration: .init(maximumInlineCharacters: 4, previewCharacters: 3)
      ),
      toolCallID: { "call-999" }
    )

    let result = try await tool.call(arguments: EmptyDeepToolArguments())

    #expect(tool.name == "expensive_search")
    #expect(tool.description == "Returns search output.")
    #expect(result.contains("COREAGENT_DEEP_TOOL_RESULT_OFFLOADED_V1"))
    #expect(result.contains("/large_tool_results/call-999"))
    #expect(
      try await filesystem.readFile(at: "/large_tool_results/call-999")
        == "abcdefghijklmnopqrstuvwxyz")
  }

  @Test("Offloading wrapper keeps small string output inline")
  func wrapperKeepsSmallStringOutputInline() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write], paths: ["/large_tool_results/**"])]
    )
    let tool = CoreAgentDeepOffloadingTool(
      tool: StaticStringTool(
        name: "small_tool", description: "Returns small output.", output: "ok"),
      offloader: CoreAgentDeepToolResultOffloader(
        filesystem: filesystem,
        configuration: .init(maximumInlineCharacters: 4)
      ),
      toolCallID: { "small-call" }
    )

    #expect(try await tool.call(arguments: EmptyDeepToolArguments()) == "ok")
    #expect(await filesystem.snapshot().isEmpty)
  }
  @Test("Encodable offloading wrapper serializes and offloads large structured output")
  func wrapperOffloadsLargeEncodableOutput() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .read], paths: ["/large_tool_results/**"])]
    )
    let offloader = CoreAgentDeepToolResultOffloader(
      filesystem: filesystem,
      configuration: CoreAgentDeepToolResultOffloadConfiguration(
        maximumInlineCharacters: 1_000,
        previewCharacters: 100
      )
    )
    let wrapped = CoreAgentDeepToolOffloading.wrapEncodable(
      LargePayloadTool(items: Array(repeating: "x", count: 5_000)),
      offloader: offloader,
      toolCallID: { "call/structured" }
    )
    let output = try await wrapped.call(arguments: EmptyDeepToolArguments())
    #expect(output.contains("COREAGENT_DEEP_TOOL_RESULT_OFFLOADED_V1"))
    #expect(output.contains("/large_tool_results/call_structured"))
  }

  @Test("Encodable offloading wrapper keeps small structured output inline")
  func wrapperKeepsSmallEncodableOutputInline() async throws {
    let filesystem = CoreAgentDeepStateFilesystem()
    let offloader = CoreAgentDeepToolResultOffloader(
      filesystem: filesystem, configuration: CoreAgentDeepToolResultOffloadConfiguration())
    let wrapped = CoreAgentDeepToolOffloading.wrapEncodable(
      LargePayloadTool(items: ["ok"]),
      offloader: offloader,
      toolCallID: { "call-small" }
    )
    let output = try await wrapped.call(arguments: EmptyDeepToolArguments())
    #expect(output.contains("items"))
    #expect(output.contains("ok"))
    #expect(!output.contains("COREAGENT_DEEP_TOOL_RESULT_OFFLOADED_V1"))
  }

}

@Generable
private struct EmptyDeepToolArguments: Sendable {}

private struct StaticStringTool: Tool {
  let name: String
  let description: String
  let output: String

  @concurrent
  func call(arguments: EmptyDeepToolArguments) async throws -> String {
    output
  }
}

@Generable
private struct LargePayload: Sendable, Codable, Equatable {
  let items: [String]
}

private struct LargePayloadTool: Tool {
  let items: [String]

  var name: String { "large_payload" }
  var description: String { "Returns a structured payload." }

  @concurrent
  func call(arguments: EmptyDeepToolArguments) async throws -> LargePayload {
    LargePayload(items: items)
  }
}
