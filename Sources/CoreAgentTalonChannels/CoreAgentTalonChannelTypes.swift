#if COREAGENT_TALON_CHANNELS
  import Foundation

  public enum CoreAgentTalonChannelKind: String, Codable, CaseIterable, Sendable {
    case whatsApp = "whatsapp"
    case telegram
    case mcp
  }

  public struct CoreAgentTalonChannelMessageID:
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

  public struct CoreAgentTalonChannelPeerID:
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

  public struct CoreAgentTalonChannelOutboundMessage:
    Codable, Equatable, Identifiable, Sendable
  {
    public let id: CoreAgentTalonChannelMessageID
    public let channel: CoreAgentTalonChannelKind
    public let peerID: CoreAgentTalonChannelPeerID
    public let text: String
    public let metadata: [String: String]

    public init(
      id: CoreAgentTalonChannelMessageID,
      channel: CoreAgentTalonChannelKind,
      peerID: CoreAgentTalonChannelPeerID,
      text: String,
      metadata: [String: String] = [:]
    ) {
      self.id = id
      self.channel = channel
      self.peerID = peerID
      self.text = text
      self.metadata = metadata
    }

    public init(
      id: String,
      channel: CoreAgentTalonChannelKind,
      peerID: CoreAgentTalonChannelPeerID,
      text: String,
      metadata: [String: String] = [:]
    ) {
      self.init(
        id: CoreAgentTalonChannelMessageID(id),
        channel: channel,
        peerID: peerID,
        text: text,
        metadata: metadata
      )
    }
  }

  public struct CoreAgentTalonChannelInboundEnvelope:
    Codable, Equatable, Identifiable, Sendable
  {
    public let id: CoreAgentTalonChannelMessageID
    public let channel: CoreAgentTalonChannelKind
    public let peerID: CoreAgentTalonChannelPeerID
    public let text: String
    public let metadata: [String: String]

    public init(
      id: CoreAgentTalonChannelMessageID,
      channel: CoreAgentTalonChannelKind,
      peerID: CoreAgentTalonChannelPeerID,
      text: String,
      metadata: [String: String] = [:]
    ) {
      self.id = id
      self.channel = channel
      self.peerID = peerID
      self.text = text
      self.metadata = metadata
    }

    public init(
      id: String,
      channel: CoreAgentTalonChannelKind,
      peerID: CoreAgentTalonChannelPeerID,
      text: String,
      metadata: [String: String] = [:]
    ) {
      self.init(
        id: CoreAgentTalonChannelMessageID(id),
        channel: channel,
        peerID: peerID,
        text: text,
        metadata: metadata
      )
    }
  }

  public struct CoreAgentTalonChannelInboundMessage:
    Codable, Equatable, Identifiable, Sendable
  {
    public let id: CoreAgentTalonChannelMessageID
    public let channel: CoreAgentTalonChannelKind
    public let peerID: CoreAgentTalonChannelPeerID
    public let text: String
    public let metadata: [String: String]

    public init(
      id: CoreAgentTalonChannelMessageID,
      channel: CoreAgentTalonChannelKind,
      peerID: CoreAgentTalonChannelPeerID,
      text: String,
      metadata: [String: String] = [:]
    ) {
      self.id = id
      self.channel = channel
      self.peerID = peerID
      self.text = text
      self.metadata = metadata
    }
  }

  public struct CoreAgentTalonChannelSendReceipt: Codable, Equatable, Sendable {
    public let messageID: CoreAgentTalonChannelMessageID
    public let channel: CoreAgentTalonChannelKind
    public let peerID: CoreAgentTalonChannelPeerID
    public let providerMessageID: String?

    public init(
      messageID: CoreAgentTalonChannelMessageID,
      channel: CoreAgentTalonChannelKind,
      peerID: CoreAgentTalonChannelPeerID,
      providerMessageID: String? = nil
    ) {
      self.messageID = messageID
      self.channel = channel
      self.peerID = peerID
      self.providerMessageID = providerMessageID
    }
  }

  public enum CoreAgentTalonChannelError: Error, Equatable, LocalizedError, Sendable {
    case channelMismatch(
      expected: CoreAgentTalonChannelKind,
      actual: CoreAgentTalonChannelKind
    )
    case peerNotAllowed(
      peerID: CoreAgentTalonChannelPeerID,
      mode: CoreAgentTalonExposureMode
    )
    case foreignOperator(
      expected: CoreAgentTalonOperatorID,
      actual: CoreAgentTalonOperatorID
    )

    public var errorDescription: String? {
      switch self {
      case .channelMismatch(let expected, let actual):
        "Expected \(expected.rawValue) channel message, got \(actual.rawValue)."
      case .peerNotAllowed(let peerID, let mode):
        "Peer \(peerID.rawValue) is not allowed by \(mode.rawValue) exposure."
      case .foreignOperator(let expected, let actual):
        "Expected operator \(expected.rawValue), got \(actual.rawValue)."
      }
    }
  }
#endif
