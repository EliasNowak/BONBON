/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import SwiftUI
import VideoToolbox

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var knownDeviceCount: Int = 0
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .low

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // Gemini Live integration
  var geminiSessionVM: GeminiSessionViewModel?

  // WebRTC Live streaming integration
  var webrtcSessionVM: WebRTCSessionViewModel?

  // The core DAT SDK stream is scoped to a DeviceSession in the vendored SDK.
  private var stream: MWDATCamera.Stream?
  private var deviceSession: DeviceSession?
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var iPhoneCameraManager: IPhoneCameraManager?

  // CPU-based CIContext for rendering decoded pixel buffers in background
  private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    self.hasActiveDevice = deviceSelector.activeDevice != nil || !wearables.devices.isEmpty
    self.knownDeviceCount = wearables.devices.count

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      await withTaskGroup(of: Void.self) { group in
        group.addTask { @MainActor [weak self] in
          guard let self else { return }
          for await device in self.deviceSelector.activeDeviceStream() {
            self.hasActiveDevice = device != nil || !self.wearables.devices.isEmpty
          }
        }

        group.addTask { @MainActor [weak self] in
          guard let self else { return }
          for await devices in self.wearables.devicesStream() {
            self.knownDeviceCount = devices.count
            self.hasActiveDevice = self.deviceSelector.activeDevice != nil || !devices.isEmpty
          }
        }
      }
    }

    setupVideoDecoder()
  }

  private func setupVideoDecoder() {
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pixelBuffer = decodedFrame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
          let image = UIImage(cgImage: cgImage)
          self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
          self.webrtcSessionVM?.pushVideoFrame(image)
          if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
            NSLog("[Stream] Background frame #%d decoded and forwarded (%dx%d)",
                  self.backgroundFrameCount, width, height)
          }
        }
      }
    }
  }

  /// Recreate the StreamSession with the current selectedResolution.
  /// Only call when not actively streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  private func makeStreamConfiguration() -> StreamConfiguration {
    StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: selectedResolution,
      frameRate: 24)
  }

  private func attachListeners(to stream: MWDATCamera.Stream) {
    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // This callback fires whether the app is in the foreground or background,
    // enabling continuous streaming even when the screen is locked.
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

        let isInBackground = UIApplication.shared.applicationState == .background

        if !isInBackground {
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          if let image = videoFrame.makeUIImage() {
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame {
              self.hasReceivedFirstFrame = true
            }
            self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
            self.webrtcSessionVM?.pushVideoFrame(image)
          }
        } else {
          // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
          // Instead, use our VideoDecoder (VTDecompressionSession) to decode compressed
          // frames into pixel buffers, then convert via CPU CIContext.
          self.backgroundFrameCount += 1

          let sampleBuffer = videoFrame.sampleBuffer
          let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil

          if hasCompressedData {
            // Compressed frame (HEVC/H.264) - decode via VTDecompressionSession
            do {
              try self.videoDecoder.decode(sampleBuffer)
            } catch {
              if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
                NSLog("[Stream] Background frame #%d decode error: %@",
                      self.backgroundFrameCount, String(describing: error))
              }
            }
          } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Raw pixel buffer - convert directly via CPU CIContext
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
              let image = UIImage(cgImage: cgImage)
              self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
              self.webrtcSessionVM?.pushVideoFrame(image)
            }
            self.videoDecoder.invalidateSession()
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Suppress device-not-found errors when user hasn't started streaming yet
        if self.streamingStatus == .stopped {
          if case .deviceNotConnected = error { return }
          if case .deviceNotFound = error { return }
        }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          showError(newErrorMessage)
        }
      }
    }

    updateStatusFromState(stream.state)

    // Subscribe to photo capture events
    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func startSession() async {
    do {
      streamingMode = .glasses
      streamingStatus = .waiting
      hasReceivedFirstFrame = false

      let session = try await getStartedDeviceSession()
      guard let stream = try session.addStream(config: makeStreamConfiguration()) else {
        throw DeviceSessionError.unexpectedError(description: "Unable to create camera stream")
      }

      self.stream = stream
      attachListeners(to: stream)
      await stream.start()
    } catch {
      streamingStatus = .stopped
      showError("Streaming failed: \(streamingErrorDescription(error))")
    }
  }

  private func getStartedDeviceSession() async throws -> DeviceSession {
    if let session = deviceSession, session.state == .started {
      return session
    }

    deviceSession?.stop()
    deviceSession = nil

    let session = try wearables.createSession(deviceSelector: deviceSelector)
    deviceSession = session

    let stateStream = session.stateStream()
    let errorStream = session.errorStream()
    try session.start()

    if session.state == .started {
      return session
    }

    try await waitForSessionStart(stateStream: stateStream, errorStream: errorStream)
    return session
  }

  private func waitForSessionStart(
    stateStream: AsyncStream<DeviceSessionState>,
    errorStream: AsyncStream<DeviceSessionError>
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await state in stateStream {
          if state == .started {
            return
          }
          if state == .stopped {
            throw DeviceSessionError.unexpectedError(description: "The session failed to start")
          }
        }
      }

      group.addTask {
        for await error in errorStream {
          throw error
        }
      }

      guard try await group.next() != nil else {
        throw DeviceSessionError.unexpectedError(description: "The session failed to start")
      }
      group.cancelAll()
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func refreshDeviceAvailability() {
    knownDeviceCount = wearables.devices.count
    hasActiveDevice = deviceSelector.activeDevice != nil || !wearables.devices.isEmpty
  }

  func stopSession() async {
    if streamingMode == .iPhone {
      stopIPhoneSession()
      return
    }
    if let stream {
      await stream.stop()
    }
    deviceSession?.stop()
    stream = nil
    deviceSession = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
  }

  func endSession() {
    Task { await stopSession() }
  }

  // MARK: - iPhone Camera Mode

  func handleStartIPhone() async {
    let granted = await IPhoneCameraManager.requestPermission()
    if granted {
      startIPhoneSession()
    } else {
      showError("Camera permission denied. Please grant access in Settings.")
    }
  }

  private func startIPhoneSession() {
    streamingMode = .iPhone
    let camera = IPhoneCameraManager()
    camera.onFrameCaptured = { [weak self] image in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentVideoFrame = image
        if !self.hasReceivedFirstFrame {
          self.hasReceivedFirstFrame = true
        }
        self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
        self.webrtcSessionVM?.pushVideoFrame(image)
      }
    }
    camera.start()
    iPhoneCameraManager = camera
    streamingStatus = .streaming
    NSLog("[Stream] iPhone camera mode started")
  }

  private func stopIPhoneSession() {
    iPhoneCameraManager?.stop()
    iPhoneCameraManager = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    streamingMode = .glasses
    NSLog("[Stream] iPhone camera mode stopped")
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    stream?.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func formatStreamingError(_ error: StreamError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    case .thermalCritical:
      return "The glasses are too warm to stream right now."
    case .thermalEmergency:
      return "Streaming stopped because the glasses overheated."
    case .peakPowerShutdown:
      return "Streaming stopped to protect the glasses battery."
    case .batteryCritical:
      return "The glasses battery is too low to stream."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }

  private func streamingErrorDescription(_ error: Error) -> String {
    if let deviceError = error as? DeviceSessionError {
      return deviceError.localizedDescription
    }
    if let streamError = error as? StreamError {
      return formatStreamingError(streamError)
    }
    return error.localizedDescription
  }
}
