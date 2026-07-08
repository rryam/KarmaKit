#if COREAGENT_TALON_CHANNELS
  public typealias CoreAgentTalonChannelSendHandler =
    @Sendable (CoreAgentTalonChannelOutboundMessage) async throws ->
    CoreAgentTalonChannelSendReceipt
  public typealias CoreAgentTalonChannelReceiveHandler =
    @Sendable (CoreAgentTalonChannelInboundEnvelope) async throws ->
    CoreAgentTalonChannelInboundMessage

  public protocol CoreAgentTalonChannelAdapter: Sendable {
    var channel: CoreAgentTalonChannelKind { get }

    func send(
      _ message: CoreAgentTalonChannelOutboundMessage
    ) async throws -> CoreAgentTalonChannelSendReceipt

    func receive(
      _ envelope: CoreAgentTalonChannelInboundEnvelope
    ) async throws -> CoreAgentTalonChannelInboundMessage
  }

  public struct CoreAgentTalonWhatsAppChannelAdapter: CoreAgentTalonChannelAdapter {
    private let adapter: CoreAgentTalonHostProvidedChannelAdapter

    public var channel: CoreAgentTalonChannelKind {
      adapter.channel
    }

    public init(
      send: @escaping CoreAgentTalonChannelSendHandler,
      receive: @escaping CoreAgentTalonChannelReceiveHandler
    ) {
      self.adapter = CoreAgentTalonHostProvidedChannelAdapter(
        channel: .whatsApp,
        send: send,
        receive: receive
      )
    }

    public func send(
      _ message: CoreAgentTalonChannelOutboundMessage
    ) async throws -> CoreAgentTalonChannelSendReceipt {
      try await adapter.send(message)
    }

    public func receive(
      _ envelope: CoreAgentTalonChannelInboundEnvelope
    ) async throws -> CoreAgentTalonChannelInboundMessage {
      try await adapter.receive(envelope)
    }
  }

  public struct CoreAgentTalonTelegramChannelAdapter: CoreAgentTalonChannelAdapter {
    private let adapter: CoreAgentTalonHostProvidedChannelAdapter

    public var channel: CoreAgentTalonChannelKind {
      adapter.channel
    }

    public init(
      send: @escaping CoreAgentTalonChannelSendHandler,
      receive: @escaping CoreAgentTalonChannelReceiveHandler
    ) {
      self.adapter = CoreAgentTalonHostProvidedChannelAdapter(
        channel: .telegram,
        send: send,
        receive: receive
      )
    }

    public func send(
      _ message: CoreAgentTalonChannelOutboundMessage
    ) async throws -> CoreAgentTalonChannelSendReceipt {
      try await adapter.send(message)
    }

    public func receive(
      _ envelope: CoreAgentTalonChannelInboundEnvelope
    ) async throws -> CoreAgentTalonChannelInboundMessage {
      try await adapter.receive(envelope)
    }
  }

  public struct CoreAgentTalonMCPChannelAdapter: CoreAgentTalonChannelAdapter {
    private let adapter: CoreAgentTalonHostProvidedChannelAdapter

    public var channel: CoreAgentTalonChannelKind {
      adapter.channel
    }

    public init(
      send: @escaping CoreAgentTalonChannelSendHandler,
      receive: @escaping CoreAgentTalonChannelReceiveHandler
    ) {
      self.adapter = CoreAgentTalonHostProvidedChannelAdapter(
        channel: .mcp,
        send: send,
        receive: receive
      )
    }

    public func send(
      _ message: CoreAgentTalonChannelOutboundMessage
    ) async throws -> CoreAgentTalonChannelSendReceipt {
      try await adapter.send(message)
    }

    public func receive(
      _ envelope: CoreAgentTalonChannelInboundEnvelope
    ) async throws -> CoreAgentTalonChannelInboundMessage {
      try await adapter.receive(envelope)
    }
  }

  private struct CoreAgentTalonHostProvidedChannelAdapter: Sendable {
    let channel: CoreAgentTalonChannelKind
    private let sendHandler: CoreAgentTalonChannelSendHandler
    private let receiveHandler: CoreAgentTalonChannelReceiveHandler

    init(
      channel: CoreAgentTalonChannelKind,
      send: @escaping CoreAgentTalonChannelSendHandler,
      receive: @escaping CoreAgentTalonChannelReceiveHandler
    ) {
      self.channel = channel
      self.sendHandler = send
      self.receiveHandler = receive
    }

    func send(
      _ message: CoreAgentTalonChannelOutboundMessage
    ) async throws -> CoreAgentTalonChannelSendReceipt {
      try validate(message.channel)
      let receipt = try await sendHandler(message)
      try validate(receipt.channel)
      return receipt
    }

    func receive(
      _ envelope: CoreAgentTalonChannelInboundEnvelope
    ) async throws -> CoreAgentTalonChannelInboundMessage {
      try validate(envelope.channel)
      let message = try await receiveHandler(envelope)
      try validate(message.channel)
      return message
    }

    private func validate(_ actual: CoreAgentTalonChannelKind) throws {
      guard actual == channel else {
        throw CoreAgentTalonChannelError.channelMismatch(expected: channel, actual: actual)
      }
    }
  }
#endif
