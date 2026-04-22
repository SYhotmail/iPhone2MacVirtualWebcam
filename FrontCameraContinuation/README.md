# FrontCameraContinuation

Use an iPhone front camera as a virtual webcam on a Mac over your local network.

The project contains:

- `FrontCameraContinuation`: the iPhone app that captures the front camera, shows a live preview, encodes the stream, and sends it to your Mac over TCP
- `TCPServer`: the macOS app that receives and previews the stream, installs the virtual camera system extension, and pushes decoded frames into the virtual camera sink stream
- `VirtualCameraExtension`: the macOS system extension that exposes the virtual camera to apps like Zoom and bridges the sink stream to the source stream apps actually read from

## How It Works

1. Run `TCPServer` on your Mac.
2. Install and activate the virtual camera from the Mac app.
3. Run `FrontCameraContinuation` on your iPhone.
4. Enter your Mac's LAN IP address and port in the iPhone app.
5. Start streaming from the iPhone.
6. Select the virtual camera(Remote Camera) in Zoom, Meet, QuickTime, or another camera app on macOS.

### Virtual Camera Architecture

The virtual camera uses two CoreMediaIO streams:

- a `sink stream`, written by `TCPServer`, which delivers decoded frames from the iPhone feed into the virtual camera device
- a `source stream`, exposed by `VirtualCameraExtension`, which is the camera stream Zoom and other macOS apps consume

In other words:

1. iPhone captures and sends H.264 over LAN
2. `TCPServer` receives and decodes the frames
3. `TCPServer` writes those frames into the virtual camera sink stream
4. `VirtualCameraExtension` forwards them to the source stream
5. Zoom reads the source stream as a normal camera device

## Screenshots

![Overview](docs/images/setup-overview.jpeg)

![iPhone and Mac apps](docs/images/iphone-mac-preview.jpeg)

## Requirements

- Xcode 17 or newer
- A physical iPhone for the sender app
- A Mac that can run a Camera Extension / System Extension
- iPhone and Mac connected to the same local network
- An Apple development signing setup that can build both the iOS app and the macOS system extension

## Project Structure

```text
FrontCameraContinuation/
  FrontCameraContinuation/   iPhone sender app
  TCPServer/                 macOS receiver + virtual camera installer
  VirtualCameraExtension/    CoreMediaIO camera extension
scripts/
  install_tcpserver_app.sh
  install_and_launch_tcpserver.sh
```

## Build and Install

### 1. Open the Project

Open:

```text
FrontCameraContinuation/FrontCameraContinuation.xcodeproj
```

You will see separate schemes for the iPhone app and the Mac app:

- `FrontCameraContinuation`
- `TCPServer`

### 2. Build and Run the Mac App

Build the `TCPServer` scheme in Xcode, or from Terminal:

```bash
xcodebuild \
  -project FrontCameraContinuation/FrontCameraContinuation.xcodeproj \
  -scheme TCPServer \
  -configuration Debug \
  build
```

To copy the built Mac app into `/Applications`:

```bash
sudo /bin/zsh scripts/install_tcpserver_app.sh TCPServer
```

Or build, install, and launch it in one step:

```bash
sudo /bin/zsh scripts/install_and_launch_tcpserver.sh TCPServer
```

Why `/Applications` matters:

- macOS system extensions are much more reliable when the host app lives in `/Applications`
- the `TCPServer` UI also reminds you to move the app there before installation

### 3. Install the Virtual Camera on macOS

After launching `TCPServer.app`:

1. Click `Install Virtual Camera`
2. Approve the system extension if macOS asks
3. If macOS requires a reboot or a retry, follow that prompt
4. When installed successfully, the virtual camera becomes available to camera-aware Mac apps

You can also use `Uninstall Virtual Camera` from the same Mac app later if needed.

### 4. Build and Run the iPhone App

Build the `FrontCameraContinuation` scheme in Xcode, then run it on a physical iPhone.

Terminal build example:

```bash
xcodebuild \
  -project FrontCameraContinuation/FrontCameraContinuation.xcodeproj \
  -scheme FrontCameraContinuation \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

When first launched on iPhone, allow camera access.

## How to Use

### On the Mac

1. Open `TCPServer.app`
2. Click `Start` to start listening for the iPhone stream
3. If not already installed, click `Install Virtual Camera`
4. Keep `TCPServer.app` running

The Mac app shows:

- the live decoded preview
- listener status
- connection status
- virtual camera installation status
- the sink-stream feed path that ultimately drives the virtual camera

### On the iPhone

1. Open `FrontCameraContinuation`
2. Enter the Mac's LAN IP address in the `Mac Address` field
3. Enter the port
4. Choose the video resolution
5. Tap `Start Stream`

The iPhone app includes a local preview so you can frame the shot before or during streaming.

## Finding the Mac LAN IP Address

The `Mac Address` field in the iPhone UI expects the Mac's IP address on your local network, for example:

```text
192.168.1.10
```

It does **not** mean the hardware MAC address.

Ways to find the Mac IP address:

- `System Settings` -> `Wi-Fi` -> connected network -> inspect the IP address
- Terminal:

```bash
ipconfig getifaddr en0
```

If your Mac is using a different interface, `en0` may be something else. The important part is to use the LAN address that your iPhone can reach on the same Wi‑Fi network.

## Default Port

The current default port used by the project is:

```text
9999
```

The Mac app listens on that port by default, and the iPhone UI also defaults to `9999`.

## Using the Virtual Camera in Zoom

After `TCPServer` is running, the virtual camera is installed, and the iPhone stream is active:

1. Open Zoom
2. Go to `Settings` -> `Video`
3. Choose the virtual camera from the `Camera` dropdown

The same idea works in other macOS apps that use standard camera devices.

## Typical Run Order

Use this order for the smoothest setup:

1. Launch `TCPServer.app` on the Mac
2. Click `Start`
3. Install the virtual camera if needed
4. Launch the iPhone app
5. Enter the Mac LAN IP and port `9999`
6. Tap `Start Stream`
7. Select the virtual camera in Zoom or another app

## Troubleshooting

### No video on the Mac

- Make sure `TCPServer.app` is running
- Make sure the Mac listener is started
- Confirm the iPhone is using the correct LAN IP address
- Confirm both devices are on the same network
- Confirm the port matches on both sides

### No video in Zoom

- Make sure the virtual camera is installed and activated
- Keep `TCPServer.app` running while Zoom is open
- Start the iPhone stream before or while Zoom is selecting the camera
- Make sure the Mac app is actively feeding the sink stream, not just sitting idle
- Re-select the virtual camera in Zoom settings if needed

### Virtual camera installation fails

- Install the Mac app into `/Applications`
- Re-open the app from `/Applications`
- Retry `Install Virtual Camera`
- Approve any macOS system extension prompt
- Reboot if macOS says the extension change is pending

## Notes

- This project is meant for development and local use
- It currently uses a direct local-network connection from iPhone to Mac
- The preview in the Mac app is useful for checking that frames are arriving even before opening Zoom

## Acknowledgements

The sink/source stream virtual camera approach used here was inspired by Laurent Denoue's sample camera extension project:

- [ldenoue/cameraextension](https://github.com/ldenoue/cameraextension)
