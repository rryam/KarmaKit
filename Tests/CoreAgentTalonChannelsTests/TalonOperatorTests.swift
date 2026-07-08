#if COREAGENT_TALON_CHANNELS
  import CoreAgentTalonChannels
  import Testing

  @Suite("TalonOperatorTests")
  struct TalonOperatorTests {
    @Test("Foreign operator identities are rejected before run dispatch")
    func rejectsForeignOperator() async throws {
      let dispatch = RunDispatchRecorder()
      let policy = CoreAgentTalonSingleOperatorPolicy(
        operatorID: "operator-1",
        exposure: .open
      )
      let validRequest = CoreAgentTalonChannelRunRequest(
        operatorID: "operator-1",
        peerID: "peer-1",
        prompt: "hello"
      )

      let validResponse = try await policy.dispatch(validRequest) { authorized in
        await dispatch.record(authorized.request)
        return "dispatched:\(authorized.request.prompt)"
      }
      #expect(validResponse == "dispatched:hello")
      #expect(await dispatch.count == 1)

      let foreignRequest = CoreAgentTalonChannelRunRequest(
        operatorID: "operator-2",
        peerID: "peer-1",
        prompt: "should not dispatch"
      )
      await #expect(
        throws: CoreAgentTalonChannelError.foreignOperator(
          expected: "operator-1", actual: "operator-2")
      ) {
        try await policy.dispatch(foreignRequest) { authorized in
          await dispatch.record(authorized.request)
          return "unexpected"
        }
      }
      #expect(await dispatch.count == 1)
    }
  }

  private actor RunDispatchRecorder {
    private var requests: [CoreAgentTalonChannelRunRequest] = []

    var count: Int {
      requests.count
    }

    func record(_ request: CoreAgentTalonChannelRunRequest) {
      requests.append(request)
    }
  }
#endif
