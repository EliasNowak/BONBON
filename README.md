# VisionClaw Wearables Hackathon

Real-time AI assistant for Meta Ray-Ban smart glasses, based on
[Intent-Lab/VisionClaw](https://github.com/Intent-Lab/VisionClaw).

This workspace contains the iOS `CameraAccess` sample with:

- Meta Wearables DAT camera streaming from glasses
- iPhone camera mode for testing without glasses
- Gemini Live voice and vision assistant
- optional OpenClaw tool routing
- optional WebRTC live POV viewer and local signaling server
- MockDeviceKit support for simulator/testing

The Meta Wearables DAT SDK is vendored locally under:

```text
Vendor/MetaWearablesDAT
```

That keeps the hackathon project reopenable without depending on Xcode package resolution for the DAT SDK itself. WebRTC is still resolved by Swift Package Manager.

## iOS Quick Start

```bash
open CameraAccess.xcodeproj
```

In Xcode, select the `CameraAccess` scheme, choose a physical iPhone, confirm signing uses your team, and run.

For Gemini/OpenClaw/WebRTC values, edit the local file:

```text
CameraAccess/Secrets.swift
```

`CameraAccess/Secrets.swift` is intentionally ignored by git. The app also has an in-app Settings screen for these values.

## Build Check

```bash
xcodebuild -quiet -project CameraAccess.xcodeproj -scheme CameraAccess -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## WebRTC Signaling Server

The optional browser POV streaming server is in:

```text
server/
```

Run it with:

```bash
cd server
npm install
npm start
```

Then set `webrtcSignalingURL` in `CameraAccess/Secrets.swift` or in app Settings.

## Run With Glasses

1. Enable Developer Mode in the Meta AI app.
2. Run this app on a physical iPhone.
3. Tap Connect.
4. Grant camera and microphone permissions.
5. Tap Start processing on glasses to start the glasses camera stream and Gemini Live together.

Use Start streaming if you only want the camera stream/photo capture without Gemini.

Without glasses, use Start on iPhone to test the voice and vision pipeline with the phone camera.
