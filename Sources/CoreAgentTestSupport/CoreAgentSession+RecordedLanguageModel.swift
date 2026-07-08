import CoreAgent
import FoundationModels

extension CoreAgentSession {
  public init(
    model recorded: RecordedLanguageModel,
    tools: [any Tool] = [],
    instructions: Instructions? = nil,
    configuration: CoreAgentConfiguration = .default,
    toolConfiguration: CoreAgentToolConfiguration = .default,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    requiresMatchingToolset: Bool = true,
    instructionRestorationPolicy: CoreAgentInstructionRestorationPolicy = .replaceWithCurrent,
    plugins: [any CoreAgentSessionPlugin] = [],
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    observers: [any CoreAgentObserver] = [],
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration = .default
  ) throws {
    try self.init(
      model: recorded,
      tools: tools,
      instructions: instructions,
      configuration: configuration,
      toolConfiguration: toolConfiguration,
      checkpointStore: checkpointStore,
      checkpointKey: checkpointKey,
      transcriptRetention: transcriptRetention,
      requiresMatchingToolset: requiresMatchingToolset,
      instructionRestorationPolicy: instructionRestorationPolicy,
      plugins: plugins,
      redactionPolicy: redactionPolicy,
      observers: observers,
      observerDeliveryConfiguration: observerDeliveryConfiguration,
      scriptedModelResponder: recorded.recorder
    )
  }

  public init<Profile: LanguageModelSession.DynamicProfile>(
    checkpointCompatibilityID: String,
    model recorded: RecordedLanguageModel,
    configuration: CoreAgentConfiguration = .default,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    plugins: [any CoreAgentSessionPlugin] = [],
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    observers: [any CoreAgentObserver] = [],
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration = .default,
    scriptedTools: [any Tool] = [],
    scriptedSuppressProfileToolOutputAudit: Bool = false,
    profile makeProfile: @escaping @Sendable () -> sending Profile
  ) throws {
    try self.init(
      checkpointCompatibilityID: checkpointCompatibilityID,
      configuration: configuration,
      checkpointStore: checkpointStore,
      checkpointKey: checkpointKey,
      transcriptRetention: transcriptRetention,
      plugins: plugins,
      redactionPolicy: redactionPolicy,
      observers: observers,
      observerDeliveryConfiguration: observerDeliveryConfiguration,
      scriptedModelResponder: recorded.recorder,
      scriptedToolsByName: Dictionary(uniqueKeysWithValues: scriptedTools.map { ($0.name, $0) }),
      scriptedSuppressProfileToolOutputAudit: scriptedSuppressProfileToolOutputAudit,
      profile: makeProfile
    )
  }
}
