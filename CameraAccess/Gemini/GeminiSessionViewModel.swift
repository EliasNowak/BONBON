import Foundation
import SwiftUI
import Combine
import MWDATCore
import MWDATDisplay

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
  @Published var cookingState: CookingSessionState? = nil  // Only set in CookClaw mode
  @Published var cookClawDisplayState: MWDATDisplay.DisplayState = .stopped
  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var cookClawBridge: CookClawBridge?
  private var toolCallRouter: ToolCallRouter?
  private var cookClawToolRouter: CookClawToolRouter?
  private let audioManager = AudioManager()
  private let eventClient = OpenClawEventClient()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private var cookClawDisplayManager: CookClawDisplayManager?
  private var cookClawDisplayRefreshTask: Task<Void, Never>?
  private var displayCancellables = Set<AnyCancellable>()

  var streamingMode: StreamingMode = .glasses
  weak var deviceSession: DeviceSession?

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open GeminiConfig.swift and replace YOUR_GEMINI_API_KEY with your key from https://aistudio.google.com/apikey"
      return
    }

    NSLog("[GeminiSession] Starting session...")
    isGeminiActive = true
    defer { NSLog("[GeminiSession] startSession finished. isGeminiActive=%@", isGeminiActive ? "true" : "false") }

    // Wire audio callbacks
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        // Mute mic while model speaks when speaker is on the phone
        // (loudspeaker + co-located mic overwhelms iOS echo cancellation)
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        if speakerOnPhone && self.geminiService.isModelSpeaking { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      self?.audioManager.playAudio(data: data)
    }

    geminiService.onInterrupted = { [weak self] in
      self?.audioManager.stopPlayback()
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        // Clear user transcript when AI finishes responding
        self.userTranscript = ""
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.aiTranscript = ""
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
      }
    }

    // Handle unexpected disconnection
    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive else { return }
        self.stopSession()
        self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
      }
    }

    // Check OpenClaw connectivity and start fresh session
    await openClawBridge.checkConnection()
    openClawBridge.resetSession()

    // Wire tool call handling - use CookClaw router in cooking mode
    if SettingsManager.shared.cookClawModeEnabled {
      let cookClaw = CookClawBridge()
      cookClawBridge = cookClaw
      cookingState = cookClaw.cookingState
      cookClawToolRouter = CookClawToolRouter(cookClawBridge: cookClaw, openClawBridge: openClawBridge)
      await setupCookClawDisplay(for: cookClaw.cookingState)

      geminiService.onToolCall = { [weak self] toolCall in
        guard let self else { return }
        Task { @MainActor in
          for call in toolCall.functionCalls {
            self.cookClawToolRouter?.handleToolCall(call) { [weak self] response in
              self?.geminiService.sendToolResponse(response)
            }
          }
        }
      }
    } else {
      toolCallRouter = ToolCallRouter(bridge: openClawBridge)

      geminiService.onToolCall = { [weak self] toolCall in
        guard let self else { return }
        Task { @MainActor in
          for call in toolCall.functionCalls {
            self.toolCallRouter?.handleToolCall(call) { [weak self] response in
              self?.geminiService.sendToolResponse(response)
            }
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
        self.cookClawToolRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }

    // Observe service state
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
        self.openClawConnectionState = self.openClawBridge.connectionState
        if let cookClawToolRouter = self.cookClawToolRouter {
          self.toolCallStatus = cookClawToolRouter.lastToolCallStatus
        } else {
          self.toolCallStatus = self.openClawBridge.lastToolCallStatus
        }
      }
    }

    // Setup audio
    do {
      NSLog("[GeminiSession] Setting up audio session...")
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
      NSLog("[GeminiSession] Audio session setup complete")
    } catch {
      NSLog("[GeminiSession] Audio setup FAILED: %@", error.localizedDescription)
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      cleanupCookClawDisplay()
      isGeminiActive = false
      return
    }

    // Connect to Gemini and wait for setupComplete
    NSLog("[GeminiSession] Connecting to Gemini WebSocket...")
    let setupOk = await geminiService.connect()

    if !setupOk {
      NSLog("[GeminiSession] Gemini connect/setup failed")
      let msg: String
      if case .error(let err) = geminiService.connectionState {
        msg = err
      } else {
        msg = "Failed to connect to Gemini"
      }
      errorMessage = msg
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      cleanupCookClawDisplay()
      isGeminiActive = false
      connectionState = .disconnected
      return
    }
    NSLog("[GeminiSession] Gemini connected and ready")

    // Start mic capture
    do {
      NSLog("[GeminiSession] Starting mic capture...")
      try audioManager.startCapture()
      NSLog("[GeminiSession] Mic capture started")
    } catch {
      NSLog("[GeminiSession] Mic capture FAILED: %@", error.localizedDescription)
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      cleanupCookClawDisplay()
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Connect to OpenClaw event stream for proactive notifications
    if SettingsManager.shared.proactiveNotificationsEnabled {
      eventClient.onNotification = { [weak self] text in
        guard let self else { return }
        Task { @MainActor in
          guard self.isGeminiActive, self.connectionState == .ready else { return }
          self.geminiService.sendTextMessage(text)
        }
      }
      eventClient.connect()
    }
  }

  func stopSession() {
    eventClient.disconnect()
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    cookClawToolRouter?.cancelAll()
    cookClawToolRouter = nil
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    cleanupCookClawDisplay()
    cookClawBridge = nil
    cookingState = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  private func setupCookClawDisplay(for state: CookingSessionState) async {
    guard streamingMode == .glasses, let deviceSession else { return }

    if let device = Wearables.shared.deviceForIdentifier(deviceSession.deviceId),
       !device.supportsDisplay() {
      NSLog(
        "[GeminiSession] Device %@ does not support display; running CookClaw without glasses display",
        deviceSession.deviceId
      )
      cookClawDisplayState = .stopped
      return
    }

    let manager = CookClawDisplayManager()
    cookClawDisplayManager = manager

    manager.$displayState
      .sink { [weak self] state in
        self?.cookClawDisplayState = state
      }
      .store(in: &displayCancellables)

    await manager.attach(to: deviceSession)
    await manager.sendCookingCard(state: state)

    cookClawDisplayRefreshTask = Task { [weak self, weak state] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled, let self, let state else { break }
        await self.cookClawDisplayManager?.sendCookingCard(state: state)
      }
    }
  }

  private func cleanupCookClawDisplay() {
    cookClawDisplayRefreshTask?.cancel()
    cookClawDisplayRefreshTask = nil
    displayCancellables.removeAll()
    cookClawDisplayState = .stopped

    let manager = cookClawDisplayManager
    cookClawDisplayManager = nil
    Task { @MainActor in
      await manager?.detach()
    }
  }

}
