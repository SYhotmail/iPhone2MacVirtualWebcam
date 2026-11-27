# AGENTS.md

This file gives coding agents a fast, practical orientation for this repository.

## What This Project Is

`iPhoneFrontCameraAsWebcam` turns an iPhone front camera feed into a virtual webcam on macOS.

Main pieces:

- `FrontCameraContinuation/FrontCameraContinuation`: iPhone sender app
- `android/`: Android sender app (Kotlin, Jetpack Compose), streams over TLS/TCP
- `FrontCameraContinuation/TCPServer`: macOS receiver app
- `FrontCameraContinuation/VirtualCameraExtension`: CoreMediaIO virtual camera extension
- `Transport`: shared networking/transport package
- `H264`: shared HEVC codec helpers (`VideoEncoder`, `VideoDecoder`; the package keeps its old name)

## Current Transport Design

The project currently uses:

- `QUIC` over `Network.framework`
- certificate-based TLS
- a private ALPN: `camera-lan-stream`
- one QUIC connection ("tunnel") per session, modeled as an `NWConnectionGroup` with `NWMultiplexGroup`:
  - one bidirectional stream for pairing and control messages (`FramePacket` framing)
  - one QUIC datagram flow (RFC 9221) for video frames

Important implications:

- Do not switch ALPN to `h2` or `h3` unless the app actually implements HTTP/2 or HTTP/3.
- The sender/receiver protocol is custom, not HTTP-based.
- Video is intentionally lossy: late or lost frames are dropped, never retransmitted. After a loss the receiver skips frames until the next keyframe and asks for one over the stream (`StreamControlMessage.keyframeRequest`, rate-limited to every 500 ms). The encoder also sends a keyframe every second.
- Each frame is split into datagrams with a 10-byte header (`VideoDatagram`) sized from the flow's `usableDatagramFrameSize` (~1,440 bytes on Wi-Fi; larger datagrams are silently dropped). `FrameReassembler` rebuilds frames on the Mac.
- Both sides must set `maxDatagramFrameSize` (in `TransportTLSParameters`), or datagram flows stay in `preparing` forever.
- A datagram flow must be extracted with the group's own QUIC options plus `isDatagram = true` (`NWConnectionGroup.extractDatagramFlow()`); fresh options fail.
- The client's multiplex group opens an implicit stream that never carries data, so the Mac takes the first stream that becomes ready as the control stream (`QUICTunnelAcceptor`).
- A client multiplex group briefly reports `waiting` before `ready`; `QUICClientConnection` only reports waits longer than 2 s.
- On iOS 18, `NWConnectionGroup(with: NWMultiplexGroup(to: .service(...)))` traps (EXC_BREAKPOINT). `QUICClientConnection` resolves the Bonjour name with a UDP `NWConnection` first and opens the group to the resolved address. Check transport changes on an iOS 18 simulator, not only macOS 26.
- The TCP transport sends frames length-prefixed on the stream; keyframe requests go back on the same stream.
- The Mac runs two listeners in one `FrameStreamServer`: QUIC (`_cam2mac._udp`, port 9999, iPhone) and TLS 1.3 over TCP (`_cam2mac._tcp`, system-picked port, Android). Both use the same identity and Bonjour name and share the one client slot. Each `TransportListener` reports its own `serviceType`.
- `PairingHello.currentVersion` is 3 (2: frames moved to datagrams; 3: video codec switched from H.264 to HEVC); mismatched apps are rejected with a version error.

## TLS Notes

Shared TLS setup lives in:

- `FrontCameraContinuation/Shared/TLSConfiguration.swift`
- `Transport/Sources/Transport/TransportTLSParameters.swift`

Identity and pairing:

- Each Mac creates its own P-256 key and self-signed certificate (`SelfSignedCertificate` in Transport, stored by `TCPServer/Model/MacIdentityStore.swift` in the Keychain). There are no bundled certificates.
- The iPhone pins the Mac certificate's SHA-256 fingerprint, learned from the pairing QR code (`PairingInvitation`, `cam2mac://pair?...`).
- The first packet on every connection is a JSON `PairingHello` (`pair` with a one-time token, or `hello` with the registered secret). The server replies with a `PairingReply` on the same bidirectional QUIC stream and accepts frames only after `ok`. `TCPServer/Model/PairingAuthority.swift` decides.
- The Mac advertises Bonjour `_cam2mac._udp`. The iPhone connects to the service name, so Mac IP changes don't matter.
- `includePeerToPeer` is on for both sides (set in `TransportTLSParameters`), so discovery and streaming also work over AWDL without a shared Wi-Fi network.
- Rebuild both iPhone and Mac apps after changing Transport or TLS code.

## Networking Behavior

The stream framing (pairing, control messages, and TCP frames) is length-prefixed:

- 4-byte header
- payload bytes

Do not assume a single `receive` call returns a full header or full frame.

The server intentionally accumulates bytes until the expected byte count is reached.

## One-Client Rule

The macOS receiver allows one actively streaming iPhone client at a time.

Behavior:

- If an existing connection has already started streaming frames, a second client is rejected.
- If an existing connection is stale and never reached real streaming, a new connection may replace it.
- A connection only counts as streaming after it authenticated and sent a frame (a complete frame reassembled from datagrams counts).

This logic lives in:

- `Transport/Sources/Transport/FrameStreamServer.swift`

## Protocol Fixtures

`ProtocolFixtures/` holds golden wire-protocol cases (pairing hello/reply JSON, QR invitation URLs, stream framing, Annex-B start codes). The Swift tests (`Transport/Tests/TransportTests/ProtocolFixtureTests.swift`, `H264/Tests/H264Tests/AnnexBFixtureTests.swift`) and the Android tests (`ProtocolFixtureTest.kt`) both read them. When changing the protocol, update the fixture and both implementations together.

## Build and Test

Useful package-level test command:

```bash
cd Transport && swift test
```

Useful app builds:

```bash
xcodebuild -project FrontCameraContinuation/FrontCameraContinuation.xcodeproj -scheme Cam2Mac -configuration Debug build
xcodebuild -project FrontCameraContinuation/FrontCameraContinuation.xcodeproj -scheme FrontCameraContinuation -configuration Debug -destination 'generic/platform=iOS' build
```

Notes:

- macOS system extension behavior is more reliable when the built Mac app lives in `/Applications`.
- Some full Xcode builds may fail locally if required developer components like the Metal toolchain are missing.

## Where To Look First

If you are changing transport or streaming behavior, start here:

- `Transport/Sources/Transport/NetworkPrimitives.swift`
- `Transport/Sources/Transport/FrameStreamClient.swift`
- `Transport/Sources/Transport/FrameStreamServer.swift`
- `Transport/Sources/Transport/QUICTunnel.swift`
- `Transport/Sources/Transport/VideoDatagram.swift`
- `Transport/Sources/Transport/TransportTLSParameters.swift`
- `FrontCameraContinuation/Shared/TLSConfiguration.swift`

If you are changing video flow, also inspect:

- `FrontCameraContinuation/FrontCameraContinuation/Model/CameraStreamer.swift`
- `FrontCameraContinuation/TCPServer/Model/ServerManager.swift`
- `H264/Sources/H264`

## Agent Guidance

- Prefer small, verifiable changes.
- Keep client and server transport changes in sync.
- When changing TLS or bundled resources, explicitly note that both apps must be rebuilt.
- When changing stream parsing, preserve partial-read safety.
- When debugging connection failures, differentiate:
  - TLS handshake problems
  - connection resets
  - framing/read-loop bugs
  - stale server connection-slot issues

## Why This File Exists

`AGENTS.md` helps coding agents avoid rediscovering project-specific constraints every session.

In this repo, the most important ones are:

- QUIC is intentionally custom-protocol, not HTTP/3
- TLS is certificate-based and pinned
- the receiver uses stream framing over QUIC
- partial reads must be handled correctly
- both apps must be rebuilt after Transport/TLS resource changes
