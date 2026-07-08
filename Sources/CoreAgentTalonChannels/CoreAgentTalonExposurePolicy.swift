#if COREAGENT_TALON_CHANNELS
  public enum CoreAgentTalonExposureMode: String, Codable, Equatable, Sendable {
    case selfOnly = "self"
    case allowlist
    case open
  }

  public struct CoreAgentTalonExposurePolicy: Codable, Equatable, Sendable {
    public let mode: CoreAgentTalonExposureMode
    public let allowedPeerIDs: Set<CoreAgentTalonChannelPeerID>

    private init(
      mode: CoreAgentTalonExposureMode,
      allowedPeerIDs: Set<CoreAgentTalonChannelPeerID>
    ) {
      self.mode = mode
      self.allowedPeerIDs = allowedPeerIDs
    }

    private enum CodingKeys: String, CodingKey {
      case mode
      case allowedPeerIDs
    }

    /// Fail-closed decoding. The synthesized initializer would bypass the `private init`
    /// and the factory invariants, so a tampered payload could construct an admit-all
    /// policy. Because a legitimate `.open` payload is value-identical to a tampered one,
    /// `mode: open` is rejected on decode entirely — the admit-all policy must be built
    /// programmatically via the `.open` factory, never rehydrated from persisted data.
    /// `selfOnly` is also validated to carry exactly one peer id.
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let mode = try container.decode(CoreAgentTalonExposureMode.self, forKey: .mode)
      let allowedPeerIDs = try container.decode(
        Set<CoreAgentTalonChannelPeerID>.self,
        forKey: .allowedPeerIDs
      )
      switch mode {
      case .open:
        throw DecodingError.dataCorruptedError(
          forKey: .mode,
          in: container,
          debugDescription:
            "An 'open' (admit-all) exposure policy cannot be decoded; construct it "
            + "programmatically via CoreAgentTalonExposurePolicy.open."
        )
      case .selfOnly:
        guard allowedPeerIDs.count == 1 else {
          throw DecodingError.dataCorruptedError(
            forKey: .allowedPeerIDs,
            in: container,
            debugDescription: "A 'self' exposure policy must list exactly one peer id."
          )
        }
      case .allowlist:
        break
      }
      self.mode = mode
      self.allowedPeerIDs = allowedPeerIDs
    }

    public static func selfOnly(
      _ peerID: CoreAgentTalonChannelPeerID
    ) -> CoreAgentTalonExposurePolicy {
      CoreAgentTalonExposurePolicy(mode: .selfOnly, allowedPeerIDs: [peerID])
    }

    public static func allowlist(
      _ peerIDs: Set<CoreAgentTalonChannelPeerID>
    ) -> CoreAgentTalonExposurePolicy {
      CoreAgentTalonExposurePolicy(mode: .allowlist, allowedPeerIDs: peerIDs)
    }

    public static let open = CoreAgentTalonExposurePolicy(mode: .open, allowedPeerIDs: [])

    public func admits(peerID: CoreAgentTalonChannelPeerID) -> Bool {
      switch mode {
      case .selfOnly, .allowlist:
        allowedPeerIDs.contains(peerID)
      case .open:
        true
      }
    }

    public func validate(peerID: CoreAgentTalonChannelPeerID) throws {
      guard admits(peerID: peerID) else {
        throw CoreAgentTalonChannelError.peerNotAllowed(peerID: peerID, mode: mode)
      }
    }
  }
#endif
