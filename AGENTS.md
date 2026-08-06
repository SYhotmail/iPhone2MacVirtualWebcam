# AGENTS.md

This file gives coding agents a fast, practical orientation for this repository.

## What This Project Is

`iPhoneFrontCameraAsWebcam` turns an iPhone front camera feed into a virtual webcam on macOS.

Main pieces:

- `FrontCameraContinuation/FrontCameraContinuation`: iPhone sender app
- `FrontCameraContinuation/TCPServer`: macOS receiver app
- `FrontCameraContinuation/VirtualCameraExtension`: CoreMediaIO virtual camera extension
- `Transport`: shared networking/transport package
- `H264`: shared codec helpers

## Current Transport Design

The project currently uses:

- `QUIC` over `Network.framework`
- certificate-based TLS
- a private ALPN: `camera-lan-stream`
- a stream-style framing layer on top of QUIC

Important implications:

- Do not switch ALPN to `h2` or `h3` unless the app actually implements HTTP/2 or HTTP/3.
- The sender/receiver protocol is custom, not HTTP-based.
- The server reads a byte stream using `FramePacket` framing.
- The current QUIC path intentionally behaves like a reliable stream, not lossy datagrams.

## TLS Notes

Shared TLS setup lives in:

- `FrontCameraContinuation/Shared/TLSConfiguration.swift`
- `Transport/Sources/Transport/TransportTLSParameters.swift`

Bundled certificate assets live in:

- `Transport/Sources/Transport/Resources/cam2mac-local-server.cer`
- `Transport/Sources/Transport/Resources/cam2mac-local-server.p12`

Important:

- The client uses certificate pinning against the bundled server certificate.
- The server presents the bundled PKCS#12 identity.
- Rebuild both iPhone and Mac apps after changing Transport resources or TLS code, because each app embeds its own package resources.
- The Mac LAN IP is expected to change, so avoid IP-specific certificate assumptions.

## Networking Behavior

The stream framing is length-prefixed:

- 4-byte header
- payload bytes

Do not assume a single `receive` call returns a full header or full frame.

The server intentionally accumulates bytes until the expected byte count is reached.

## One-Client Rule

The macOS receiver allows one actively streaming iPhone client at a time.

Behavior:

- If an existing connection has already started streaming frames, a second client is rejected.
- If an existing connection is stale and never reached real streaming, a new connection may replace it.

This logic lives in:

- `Transport/Sources/Transport/FrameStreamServer.swift`

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
