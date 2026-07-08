#if COREAGENT_TALON_CHANNELS
  import CoreAgentTalonChannels
  import Foundation
  import Testing

  @Suite("TalonExposureTests")
  struct TalonExposureTests {
    @Test("Exposure policies fail closed except open mode")
    func failsClosed() throws {
      let operatorPeer = CoreAgentTalonChannelPeerID("operator")
      let allowedPeer = CoreAgentTalonChannelPeerID("allowed")
      let foreignPeer = CoreAgentTalonChannelPeerID("foreign")

      let selfOnly = CoreAgentTalonExposurePolicy.selfOnly(operatorPeer)
      try selfOnly.validate(peerID: operatorPeer)
      #expect(
        throws: CoreAgentTalonChannelError.peerNotAllowed(peerID: foreignPeer, mode: .selfOnly)
      ) {
        try selfOnly.validate(peerID: foreignPeer)
      }

      let allowlist = CoreAgentTalonExposurePolicy.allowlist([allowedPeer])
      try allowlist.validate(peerID: allowedPeer)
      #expect(
        throws: CoreAgentTalonChannelError.peerNotAllowed(peerID: foreignPeer, mode: .allowlist)
      ) {
        try allowlist.validate(peerID: foreignPeer)
      }

      let emptyAllowlist = CoreAgentTalonExposurePolicy.allowlist([])
      #expect(
        throws: CoreAgentTalonChannelError.peerNotAllowed(peerID: allowedPeer, mode: .allowlist)
      ) {
        try emptyAllowlist.validate(peerID: allowedPeer)
      }

      let open = CoreAgentTalonExposurePolicy.open
      try open.validate(peerID: operatorPeer)
      try open.validate(peerID: foreignPeer)
    }

    @Test("Decoding rejects a tampered admit-all policy")
    func decodingRejectsForgedOpenPolicy() throws {
      // A tampered payload asserting admit-all must not rehydrate into an `open` policy;
      // the admit-all state is only reachable via the programmatic `.open` factory.
      let forgedOpen = Data(#"{"mode":"open","allowedPeerIDs":[]}"#.utf8)
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(CoreAgentTalonExposurePolicy.self, from: forgedOpen)
      }

      // A `self` policy claiming more than one peer is rejected too.
      let forgedSelf = Data(#"{"mode":"self","allowedPeerIDs":["a","b"]}"#.utf8)
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(CoreAgentTalonExposurePolicy.self, from: forgedSelf)
      }
    }

    @Test("Legitimate self and allowlist policies round-trip")
    func legitimatePoliciesRoundTrip() throws {
      let operatorPeer = CoreAgentTalonChannelPeerID("operator")
      let allowed = Set(
        [CoreAgentTalonChannelPeerID("a"), CoreAgentTalonChannelPeerID("b")])
      let policies = [
        CoreAgentTalonExposurePolicy.selfOnly(operatorPeer),
        CoreAgentTalonExposurePolicy.allowlist(allowed),
      ]
      for policy in policies {
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(
          CoreAgentTalonExposurePolicy.self, from: data)
        #expect(decoded == policy)
      }
    }
  }
#endif
