# Protocol fixtures

Golden test cases for the wire protocol between the senders (iPhone, Android) and the Mac receiver.
Both test suites read these files, so a change to the protocol on one side fails the other side's tests
until both agree.

| File | Swift test | Kotlin test |
|---|---|---|
| `pairing-hello.json` | `Transport/Tests/TransportTests/ProtocolFixtureTests.swift` | `android/app/src/test/.../ProtocolFixtureTest.kt` |
| `pairing-reply.json` | same | same |
| `pairing-invitation.json` | same | same |
| `frame-packet.json` | same | same |
| `video-datagram.json` | `Transport/Tests/TransportTests/ProtocolFixtureTests.swift` | `android/app/src/test/.../ProtocolFixtureTest.kt` |
| `annexb-start-codes.json` | `H264/Tests/H264Tests/AnnexBFixtureTests.swift` | same |

Byte strings are lowercase hex. JSON payloads are compared as parsed JSON, so key order and escaping
(Swift writes `\/`) don't matter. Change a fixture only together with the code on both sides.
