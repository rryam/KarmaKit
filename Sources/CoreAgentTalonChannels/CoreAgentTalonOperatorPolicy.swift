#if COREAGENT_TALON_CHANNELS
  public struct CoreAgentTalonOperatorID:
    RawRepresentable,
    Codable,
    Hashable,
    Sendable,
    ExpressibleByStringLiteral,
    CustomStringConvertible
  {
    public let rawValue: String

    public init(_ rawValue: String) {
      self.rawValue = rawValue
    }

    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
      self.rawValue = value
    }

    public var description: String {
      rawValue
    }
  }

  public struct CoreAgentTalonChannelRunRequest: Codable, Equatable, Sendable {
    public let operatorID: CoreAgentTalonOperatorID
    public let peerID: CoreAgentTalonChannelPeerID
    public let prompt: String
    public let metadata: [String: String]

    public init(
      operatorID: CoreAgentTalonOperatorID,
      peerID: CoreAgentTalonChannelPeerID,
      prompt: String,
      metadata: [String: String] = [:]
    ) {
      self.operatorID = operatorID
      self.peerID = peerID
      self.prompt = prompt
      self.metadata = metadata
    }
  }

  public struct CoreAgentTalonAuthorizedChannelRunRequest: Equatable, Sendable {
    public let request: CoreAgentTalonChannelRunRequest

    public init(request: CoreAgentTalonChannelRunRequest) {
      self.request = request
    }
  }

  public struct CoreAgentTalonSingleOperatorPolicy: Codable, Equatable, Sendable {
    public let operatorID: CoreAgentTalonOperatorID
    public let exposure: CoreAgentTalonExposurePolicy

    public init(
      operatorID: CoreAgentTalonOperatorID,
      exposure: CoreAgentTalonExposurePolicy
    ) {
      self.operatorID = operatorID
      self.exposure = exposure
    }

    public func authorize(
      _ request: CoreAgentTalonChannelRunRequest
    ) throws -> CoreAgentTalonAuthorizedChannelRunRequest {
      guard request.operatorID == operatorID else {
        throw CoreAgentTalonChannelError.foreignOperator(
          expected: operatorID,
          actual: request.operatorID
        )
      }
      try exposure.validate(peerID: request.peerID)
      return CoreAgentTalonAuthorizedChannelRunRequest(request: request)
    }

    public func dispatch<Output: Sendable>(
      _ request: CoreAgentTalonChannelRunRequest,
      using dispatchRun:
        @Sendable (
          CoreAgentTalonAuthorizedChannelRunRequest
        ) async throws -> Output
    ) async throws -> Output {
      let authorization = try authorize(request)
      return try await dispatchRun(authorization)
    }
  }
#endif
