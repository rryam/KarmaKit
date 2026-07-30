import Foundation
import FoundationModelsAgent

public enum FoundationModelsAgentProviderModels {}

public enum FoundationModelsAgentProviderFeatures {
  #if FOUNDATIONMODELSAGENT_APPLE_UTILITIES
    public static let appleUtilities = true
  #else
    public static let appleUtilities = false
  #endif

  #if FOUNDATIONMODELSAGENT_CLAUDE
    public static let claude = true
  #else
    public static let claude = false
  #endif

  #if FOUNDATIONMODELSAGENT_GEMINI
    public static let gemini = true
  #else
    public static let gemini = false
  #endif
}

#if FOUNDATIONMODELSAGENT_APPLE_UTILITIES
  import FoundationModelsUtilities

  extension FoundationModelsAgentProviderModels {
    /// Creates Apple's generic language model for a Chat Completions endpoint.
    ///
    /// This is a protocol client for local, self-hosted, or developer-controlled
    /// servers. It is not an official OpenAI client and does not provide secure
    /// client-side credential management for hosted model APIs.
    public static func chatCompletions(
      name: String,
      baseURL: URL,
      headers: [String: String] = [:],
      supportsGuidedGeneration: Bool = true
    ) -> ChatCompletionsLanguageModel {
      ChatCompletionsLanguageModel(
        name: name,
        url: baseURL,
        additionalHeaders: headers,
        supportsGuidedGeneration: supportsGuidedGeneration
      )
    }
  }
#endif

#if FOUNDATIONMODELSAGENT_CLAUDE
  import ClaudeForFoundationModels

  /// Anthropic's first-party Foundation Models implementation.
  public typealias AnthropicLanguageModel = ClaudeLanguageModel
  public typealias AnthropicModel = ClaudeModel
  public typealias AnthropicAuthMode = AuthMode
  public typealias AnthropicServerTool = ClaudeServerTool

  extension FoundationModelsAgentProviderModels {
    public static func claude(
      model: AnthropicModel = .sonnet4_6,
      auth: AnthropicAuthMode,
      fixedEffort: AnthropicModel.Effort? = nil,
      serverTools: Set<AnthropicServerTool> = [],
      baseURL: URL = AnthropicLanguageModel.defaultBaseURL,
      timeout: TimeInterval = 60
    ) -> AnthropicLanguageModel {
      AnthropicLanguageModel(
        name: model,
        auth: auth,
        fixedEffort: fixedEffort,
        serverTools: serverTools,
        baseURL: baseURL,
        timeout: timeout
      )
    }
  }
#endif

#if FOUNDATIONMODELSAGENT_GEMINI
  import FirebaseAILogic

  /// Firebase AI Logic's first-party Gemini Foundation Models implementation.
  public typealias GoogleGeminiLanguageModel = GeminiLanguageModel
  public typealias FirebaseAIClient = FirebaseAI

  extension FoundationModelsAgentProviderModels {
    public static func gemini(
      using client: FirebaseAIClient,
      name: String,
      safetySettings: [SafetySetting]? = nil,
      options: GeminiGenerationOptions? = nil,
      serverTools: [any GeminiTool]? = nil,
      requestOptions: RequestOptions = RequestOptions()
    ) -> GoogleGeminiLanguageModel {
      client.geminiLanguageModel(
        name: name,
        safetySettings: safetySettings,
        options: options,
        serverTools: serverTools,
        requestOptions: requestOptions
      )
    }
  }
#endif
