import Foundation
import SwiftUI
import WebRTC

enum WebRTCConnectionState: Equatable {
  case disconnected
  case connecting
  case waitingForPeer
  case connected
  case error(String)
}

/// Orchestrates WebRTC live streaming with auto-pairing (no room codes).
/// The first client to connect is the creator, the second is the viewer.
@MainActor
class WebRTCSessionViewModel: ObservableObject {
  @Published var isActive: Bool = false
  @Published var connectionState: WebRTCConnectionState = .disconnected
  @Published var roomCode: String = ""
  @Published var isMuted: Bool = false
  @Published var errorMessage: String?
  @Published var remoteVideoTrack: RTCVideoTrack?
  @Published var hasRemoteVideo: Bool = false

  private var webRTCClient: WebRTCClient?
  private var signalingClient: SignalingClient?
  private var delegateAdapter: WebRTCDelegateAdapter?
  private var lastOverlaySentTime: Date?

  /// Starts the WebRTC session. Pass videoOnly=true when Gemini is active (no mic conflict).
  func startSession(videoOnly: Bool = false) async {
    guard !isActive else { return }
    guard WebRTCConfig.isConfigured else {
      errorMessage = "WebRTC signaling URL not configured."
      return
    }

    isActive = true
    connectionState = .connecting

    let iceServers = await WebRTCConfig.fetchIceServers()
    setupWebRTCClient(videoOnly: videoOnly, iceServers: iceServers)
    connectSignaling()
  }

  func stopSession() {
    webRTCClient?.close()
    webRTCClient = nil
    delegateAdapter = nil
    signalingClient?.disconnect()
    signalingClient = nil
    isActive = false
    connectionState = .disconnected
    roomCode = ""
    isMuted = false
    remoteVideoTrack = nil
    hasRemoteVideo = false
  }

  func toggleMute() {
    isMuted.toggle()
    webRTCClient?.muteAudio(isMuted)
  }

  /// Called by StreamSessionViewModel on each video frame.
  func pushVideoFrame(_ image: UIImage) {
    guard isActive, connectionState == .connected else { return }
    webRTCClient?.pushVideoFrame(image)
  }

  // MARK: - WebRTC + Signaling Setup

  private func setupWebRTCClient(videoOnly: Bool, iceServers: [RTCIceServer]?) {
    let client = WebRTCClient()
    let adapter = WebRTCDelegateAdapter(viewModel: self)
    delegateAdapter = adapter
    client.delegate = adapter
    client.setup(videoOnly: videoOnly, iceServers: iceServers)
    webRTCClient = client
  }

  private func connectSignaling() {
    signalingClient?.disconnect()

    let signaling = SignalingClient()
    signalingClient = signaling

    signaling.onConnected = { [weak self] in
      Task { @MainActor in
        self?.signalingClient?.createRoom()
      }
    }

    signaling.onMessageReceived = { [weak self] message in
      Task { @MainActor in
        self?.handleSignalingMessage(message)
      }
    }

    signaling.onDisconnected = { [weak self] reason in
      Task { @MainActor in
        guard let self, self.isActive else { return }
        NSLog("[WebRTC] Signaling disconnected: %@. Reconnecting in 2s...", reason ?? "unknown")
        self.connectionState = .connecting
        // Reconnect after delay instead of giving up
        Task {
          try? await Task.sleep(nanoseconds: 2_000_000_000)
          guard self.isActive else { return }
          self.connectSignaling()
        }
      }
    }

    guard let url = URL(string: WebRTCConfig.signalingServerURL) else {
      errorMessage = "Invalid signaling URL"
      isActive = false
      connectionState = .disconnected
      return
    }
    signaling.connect(url: url)
  }

  // MARK: - Signaling Message Handling

  private func handleSignalingMessage(_ message: SignalingMessage) {
    switch message {
    case .roomCreated(let code):
      roomCode = code
      connectionState = .waitingForPeer
      NSLog("[WebRTC] Connected to server, waiting for viewer...")

    case .roomRejoined(let code):
      roomCode = code
      connectionState = .waitingForPeer
      NSLog("[WebRTC] Reconnected to server, waiting for viewer...")

    case .peerJoined:
      NSLog("[WebRTC] Peer joined, creating offer")
      webRTCClient?.createOffer { [weak self] sdp in
        self?.signalingClient?.send(sdp: sdp)
      }

    case .answer(let sdp):
      webRTCClient?.set(remoteSdp: sdp) { error in
        if let error {
          NSLog("[WebRTC] Error setting remote SDP: %@", error.localizedDescription)
        }
      }

    case .candidate(let candidate):
      webRTCClient?.set(remoteCandidate: candidate) { error in
        if let error {
          NSLog("[WebRTC] Error adding ICE candidate: %@", error.localizedDescription)
        }
      }

    case .peerLeft:
      NSLog("[WebRTC] Peer left")
      connectionState = .waitingForPeer

    case .error(let msg):
      errorMessage = msg

    case .roomJoined, .offer:
      break
    }
  }

  // MARK: - Connection State Updates (from WebRTCClient delegate)

  fileprivate func handleConnectionStateChange(_ state: RTCIceConnectionState) {
    switch state {
    case .connected, .completed:
      connectionState = .connected
      NSLog("[WebRTC] Peer connected")
    case .disconnected:
      connectionState = .waitingForPeer
    case .failed:
      connectionState = .error("Connection failed")
    case .closed:
      connectionState = .disconnected
    default:
      break
    }
  }

  fileprivate func handleGeneratedCandidate(_ candidate: RTCIceCandidate) {
    signalingClient?.send(candidate: candidate)
  }

  fileprivate func handleRemoteVideoTrackReceived(_ track: RTCVideoTrack) {
    remoteVideoTrack = track
    hasRemoteVideo = true
    NSLog("[WebRTC] Remote video track received")
  }

  fileprivate func handleRemoteVideoTrackRemoved(_ track: RTCVideoTrack) {
    remoteVideoTrack = nil
    hasRemoteVideo = false
    NSLog("[WebRTC] Remote video track removed")
  }

  // MARK: - Overlay Sender

  /// Push a cooking-state snapshot over the signaling WebSocket so the
  /// web viewer can render an HTML overlay. Rate-limited to ~2 Hz.
  @MainActor
  func sendOverlay(snapshot: WebRTCOverlaySnapshot?) {
    guard isActive, connectionState == .connected else { return }

    let now = Date()
    if let last = lastOverlaySentTime, now.timeIntervalSince(last) < 0.5 { return }
    lastOverlaySentTime = now

    guard let snapshot,
          let data = try? JSONEncoder().encode(snapshot),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }

    signalingClient?.send(overlay: payload)
    NSLog("[WebRTC] Overlay snapshot sent")
  }
}

// MARK: - Delegate Adapter (bridges nonisolated delegate to @MainActor ViewModel)

private class WebRTCDelegateAdapter: WebRTCClientDelegate {
  private weak var viewModel: WebRTCSessionViewModel?

  init(viewModel: WebRTCSessionViewModel) {
    self.viewModel = viewModel
  }

  func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState) {
    Task { @MainActor [weak self] in
      self?.viewModel?.handleConnectionStateChange(state)
    }
  }

  func webRTCClient(_ client: WebRTCClient, didGenerateCandidate candidate: RTCIceCandidate) {
    Task { @MainActor [weak self] in
      self?.viewModel?.handleGeneratedCandidate(candidate)
    }
  }

  func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: RTCVideoTrack) {
    Task { @MainActor [weak self] in
      self?.viewModel?.handleRemoteVideoTrackReceived(track)
    }
  }

  func webRTCClient(_ client: WebRTCClient, didRemoveRemoteVideoTrack track: RTCVideoTrack) {
    Task { @MainActor [weak self] in
      self?.viewModel?.handleRemoteVideoTrackRemoved(track)
    }
  }
}
