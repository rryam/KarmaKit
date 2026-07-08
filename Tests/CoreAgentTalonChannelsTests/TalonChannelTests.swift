#if COREAGENT_TALON_CHANNELS
  import CoreAgentTalonChannels
  import Testing

  @Suite("TalonChannelTests")
  struct TalonChannelTests {
    @Test("Typed adapter contract maps send and receive without network")
    func typedAdapterContract() async throws {
      let sentMessages = ChannelRecorder()
      let adapters: [any CoreAgentTalonChannelAdapter] = [
        CoreAgentTalonWhatsAppChannelAdapter(
          send: { message in await sentMessages.record(message) },
          receive: { envelope in
            CoreAgentTalonChannelInboundMessage(
              id: envelope.id,
              channel: envelope.channel,
              peerID: envelope.peerID,
              text: envelope.text
            )
          }
        ),
        CoreAgentTalonTelegramChannelAdapter(
          send: { message in await sentMessages.record(message) },
          receive: { envelope in
            CoreAgentTalonChannelInboundMessage(
              id: envelope.id,
              channel: envelope.channel,
              peerID: envelope.peerID,
              text: envelope.text
            )
          }
        ),
        CoreAgentTalonMCPChannelAdapter(
          send: { message in await sentMessages.record(message) },
          receive: { envelope in
            CoreAgentTalonChannelInboundMessage(
              id: envelope.id,
              channel: envelope.channel,
              peerID: envelope.peerID,
              text: envelope.text
            )
          }
        ),
      ]

      for adapter in adapters {
        let outbound = CoreAgentTalonChannelOutboundMessage(
          id: "out-\(adapter.channel.rawValue)",
          channel: adapter.channel,
          peerID: "peer-1",
          text: "hello \(adapter.channel.rawValue)"
        )
        let receipt = try await adapter.send(outbound)
        #expect(receipt.messageID == outbound.id)
        #expect(receipt.channel == adapter.channel)

        let inbound = try await adapter.receive(
          CoreAgentTalonChannelInboundEnvelope(
            id: "in-\(adapter.channel.rawValue)",
            channel: adapter.channel,
            peerID: "peer-1",
            text: "reply \(adapter.channel.rawValue)"
          )
        )
        #expect(inbound.channel == adapter.channel)
        #expect(inbound.peerID == "peer-1")
        #expect(inbound.text.hasPrefix("reply"))
      }

      #expect(await sentMessages.channels == [.whatsApp, .telegram, .mcp])
    }
  }

  private actor ChannelRecorder {
    private var recordedChannels: [CoreAgentTalonChannelKind] = []

    var channels: [CoreAgentTalonChannelKind] {
      recordedChannels
    }

    func record(
      _ message: CoreAgentTalonChannelOutboundMessage
    ) -> CoreAgentTalonChannelSendReceipt {
      recordedChannels.append(message.channel)
      return CoreAgentTalonChannelSendReceipt(
        messageID: message.id,
        channel: message.channel,
        peerID: message.peerID
      )
    }
  }
#endif
