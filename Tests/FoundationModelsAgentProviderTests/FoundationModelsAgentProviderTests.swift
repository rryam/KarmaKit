import Foundation
import FoundationModelsAgent
import FoundationModelsAgentProviders
import Testing

#if FOUNDATIONMODELSAGENT_APPLE_UTILITIES
  @Suite("Apple utilities provider smoke tests")
  struct AppleUtilitiesProviderTests {
    @Test("Constructs the generic Chat Completions client without a request")
    func constructionOnly() throws {
      let model = FoundationModelsAgentProviderModels.chatCompletions(
        name: "placeholder",
        baseURL: URL(string: "https://example.invalid")!,
        supportsGuidedGeneration: false
      )
      _ = try FoundationModelsAgentSession(model: model)
      #expect(FoundationModelsAgentProviderFeatures.appleUtilities)
    }
  }
#endif

#if FOUNDATIONMODELSAGENT_CLAUDE
  @Suite("Claude provider smoke tests")
  struct ClaudeProviderTests {
    @Test("Constructs the first-party Claude provider without sending a request")
    func constructionOnly() throws {
      let model = FoundationModelsAgentProviderModels.claude(auth: .apiKey("unused-placeholder"))
      _ = try FoundationModelsAgentSession(model: model)
      #expect(FoundationModelsAgentProviderFeatures.claude)
    }
  }
#endif

#if FOUNDATIONMODELSAGENT_GEMINI
  @Suite("Gemini provider smoke tests")
  struct GeminiProviderTests {
    @Test("Compiles the first-party Gemini provider without requiring Firebase configuration")
    func compileOnly() {
      #expect(FoundationModelsAgentProviderFeatures.gemini)
    }

    // This function is deliberately not executed. Constructing FirebaseAI at
    // runtime requires an app's GoogleService-Info.plist, while type-checking it
    // proves the adapter returns a Foundation Models LanguageModel accepted by
    // FoundationModelsAgent with no network request or secret.
    private func compileSession(client: FirebaseAIClient) throws {
      let model = FoundationModelsAgentProviderModels.gemini(
        using: client, name: "gemini-placeholder")
      _ = try FoundationModelsAgentSession(model: model)
    }
  }
#endif
