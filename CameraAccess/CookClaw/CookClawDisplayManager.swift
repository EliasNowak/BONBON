import Foundation
import MWDATCore
import MWDATDisplay
import Combine

/// Manages sending CookClaw cooking instruction cards to the Meta glasses display.
/// Integrates with MWDATDisplay to render real-time recipe step, timer, and warning UI.
@MainActor
class CookClawDisplayManager: ObservableObject {
  @Published var displayState: MWDATDisplay.DisplayState = .stopped
  @Published var lastError: String?

  private var display: MWDATDisplay.Display?
  private var stateListenerToken: AnyListenerToken?
  private var deviceSession: DeviceSession?

  /// Attach to an existing started device session and start the display.
  func attach(to session: DeviceSession) async {
    guard self.deviceSession == nil else { return }
    self.deviceSession = session

    do {
      let display = try session.addDisplay()
      self.display = display

      // Observe display state
      stateListenerToken = display.statePublisher
        .listen { [weak self] state in
          Task { @MainActor in
            self?.displayState = state
          }
        }

      await display.start()
      NSLog("[CookClawDisplay] Display started")
    } catch {
      lastError = "Display attach failed: \(error.localizedDescription)"
      NSLog("[CookClawDisplay] Attach error: %@", error.localizedDescription)
    }
  }

  /// Detach and clean up display.
  func detach() async {
    if let display {
      await display.stop()
    }
    stateListenerToken = nil
    display = nil
    deviceSession = nil
    displayState = .stopped
  }

  /// Send a cooking instruction card based on current session state.
  func sendCookingCard(state: CookingSessionState) async {
    guard let display, displayState == .started else { return }

    let view = buildCookingView(state: state)
    do {
      try await display.send(view)
    } catch {
      lastError = "Send failed: \(error.localizedDescription)"
      NSLog("[CookClawDisplay] Send error: %@", error.localizedDescription)
    }
  }

  // MARK: - View Builders

  private func buildCookingView(state: CookingSessionState) -> MWDATDisplay.FlexBox {
    let recipeTitle = state.currentRecipe?.title ?? "CookClaw"
    let step = state.currentStep
    let progressText = progressText(state: state)
    let timerText = activeTimerText(state: state)
    let warning = state.detectedWarnings.last

    return MWDATDisplay.FlexBox(
      direction: .column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch,
      padding: MWDATDisplay.EdgeInsets(all: 16)
    ) {
      // Header row: icon + recipe title
      MWDATDisplay.FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
        MWDATDisplay.Icon(name: .forkKnife, style: .filled)
        MWDATDisplay.Text(recipeTitle, style: .meta, color: .secondary)
      }

      // Progress line
      if !progressText.isEmpty {
        MWDATDisplay.Text(progressText, style: .meta, color: .secondary)
      }

      // Current step heading
      if let step {
        MWDATDisplay.Text(step.instruction, style: .heading)
      } else if state.isComplete {
        MWDATDisplay.Text("All done! Enjoy your meal.", style: .heading)
      } else {
        MWDATDisplay.Text("Ready to cook?", style: .heading)
      }

      // Visual cue / body detail
      if let cue = step?.visualCue, !cue.isEmpty {
        MWDATDisplay.Text("Look for: \(cue)", style: .body, color: .secondary)
      }

      // Target temperature if present
      if let temp = step?.targetTemperature, !temp.isEmpty {
        MWDATDisplay.Text("Heat: \(temp)", style: .body, color: .secondary)
      }

      // Active timer
      if !timerText.isEmpty {
        MWDATDisplay.FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
          MWDATDisplay.Icon(name: .clock, style: .filled)
          MWDATDisplay.Text(timerText, style: .body)
        }
      }

      // Warning banner
      if let warning {
        MWDATDisplay.FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
          MWDATDisplay.Icon(name: .exclamationTriangle, style: .filled)
          MWDATDisplay.Text(warning.message, style: .body, color: .secondary)
        }
        .padding(12)
        .background(.card)
      }

      // Bottom controls (only if paused or complete)
      if state.isPaused || state.isComplete {
        MWDATDisplay.FlexBox(direction: .row, spacing: 8, alignment: .center) {
          if state.isPaused {
            MWDATDisplay.Button(label: "Resume", style: .primary, iconName: .arrowRight) {
              // Tap handled by user voice; no-op here
            }
          }
          if state.isComplete {
            MWDATDisplay.Button(label: "New Recipe", style: .secondary, iconName: .arrowRight) {
              // Tap handled by user voice; no-op here
            }
          }
        }
      }
    }
    .background(.card)
  }

  private func progressText(state: CookingSessionState) -> String {
    guard let recipe = state.currentRecipe else { return "" }
    let total = recipe.steps.count
    let done = state.completedStepIds.count
    let pct = Int(state.progressPercentage * 100)
    return "Step \(done)/\(total) • \(pct)%"
  }

  private func activeTimerText(state: CookingSessionState) -> String {
    guard !state.activeTimers.isEmpty else { return "" }
    let timers = state.activeTimers
      .filter { !$0.isFinished }
      .map { "\($0.name): \($0.formattedRemaining)" }
    return timers.joined(separator: " • ")
  }
}
