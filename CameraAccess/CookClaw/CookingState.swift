import Foundation

// MARK: - Recipe Models

/// A parsed recipe with atomic steps for tracking cooking progress
struct Recipe: Codable, Equatable {
  let title: String
  let totalTimeMinutes: Int?
  let servings: Int?
  let source: String?  // URL or "user-provided"
  let ingredients: [Ingredient]
  let steps: [RecipeStep]
  let tags: [String]  // e.g., "vegetarian", "quick", "beginner"
  
  var prepSteps: [RecipeStep] { steps.filter { $0.type == .prep } }
  var activeCookingSteps: [RecipeStep] { steps.filter { $0.type == .activeCooking } }
  var waitingSteps: [RecipeStep] { steps.filter { $0.type == .waiting } }
  var platingSteps: [RecipeStep] { steps.filter { $0.type == .plating } }
}

struct Ingredient: Codable, Equatable {
  let name: String
  let quantity: String?  // e.g., "2 cups", "1 tbsp"
  let preparation: String?  // e.g., "diced", "minced", "at room temp"
  let isOptional: Bool
  let isChecked: Bool  // user marks when they have it ready
}

enum RecipeStepType: String, Codable {
  case prep
  case activeCooking
  case waiting
  case plating
}

struct RecipeStep: Codable, Equatable, Identifiable {
  let id: String
  let type: RecipeStepType
  let instruction: String
  let estimatedDurationSeconds: Int?  // for timer steps
  let targetTemperature: String?  // e.g., "350°F", "medium-high heat"
  let visualCue: String?  // what the user should see, e.g., "golden brown", "bubbling"
  let safetyNote: String?  // e.g., "oil is hot", "raw chicken handling"
  let dependsOnStepIds: [String]  // prerequisite steps
  let isOptional: Bool
}

// MARK: - Cooking Session State

/// Tracks real-time progress through a recipe
@MainActor
class CookingSessionState: ObservableObject {
  @Published var currentRecipe: Recipe?
  @Published var currentStepIndex: Int = 0
  @Published var completedStepIds: Set<String> = []
  @Published var activeTimers: [CookingTimer] = []
  @Published var detectedWarnings: [CookingWarning] = []
  @Published var ingredientsReady: Set<String> = []  // ingredient names marked ready
  @Published var sessionStartTime: Date?
  @Published var isPaused: Bool = false
  
  // Confidence tracking for AI inference
  @Published var lastSceneDescription: String = ""
  @Published var lastUserTranscript: String = ""
  @Published var stepConfidence: Double = 0.0  // 0.0-1.0
  
  var currentStep: RecipeStep? {
    guard let recipe = currentRecipe, currentStepIndex < recipe.steps.count else { return nil }
    return recipe.steps[currentStepIndex]
  }
  
  var completedSteps: [RecipeStep] {
    guard let recipe = currentRecipe else { return [] }
    return recipe.steps.filter { completedStepIds.contains($0.id) }
  }
  
  var remainingSteps: [RecipeStep] {
    guard let recipe = currentRecipe else { return [] }
    return recipe.steps.filter { !completedStepIds.contains($0.id) }
  }
  
  var progressPercentage: Double {
    guard let recipe = currentRecipe, !recipe.steps.isEmpty else { return 0 }
    return Double(completedStepIds.count) / Double(recipe.steps.count)
  }
  
  var isComplete: Bool {
    guard let recipe = currentRecipe else { return false }
    return completedStepIds.count == recipe.steps.count
  }
  
  // MARK: - Session Control
  
  func startRecipe(_ recipe: Recipe) {
    currentRecipe = recipe
    currentStepIndex = 0
    completedStepIds.removeAll()
    activeTimers.removeAll()
    detectedWarnings.removeAll()
    ingredientsReady.removeAll()
    sessionStartTime = Date()
    isPaused = false
    lastSceneDescription = ""
    lastUserTranscript = ""
    stepConfidence = 0.0
  }
  
  func pause() {
    isPaused = true
    // Pause all active timers
    for timer in activeTimers {
      timer.pause()
    }
  }
  
  func resume() {
    isPaused = false
    for timer in activeTimers {
      timer.resume()
    }
  }
  
  func completeCurrentStep() {
    guard let step = currentStep else { return }
    completedStepIds.insert(step.id)
    
    // Advance to next incomplete step
    advanceToNextStep()
  }
  
  func advanceToNextStep() {
    guard let recipe = currentRecipe else { return }
    
    // Find the next step that isn't completed
    for i in (currentStepIndex + 1)..<recipe.steps.count {
      let step = recipe.steps[i]
      if !completedStepIds.contains(step.id) {
        currentStepIndex = i
        return
      }
    }
    
    // All steps complete
    currentStepIndex = recipe.steps.count
  }
  
  func goToStep(id: String) {
    guard let recipe = currentRecipe,
          let index = recipe.steps.firstIndex(where: { $0.id == id }) else { return }
    currentStepIndex = index
  }
  
  func markStepComplete(id: String) {
    completedStepIds.insert(id)
  }
  
  func markIngredientReady(_ ingredientName: String) {
    ingredientsReady.insert(ingredientName.lowercased())
  }
  
  func addTimer(name: String, durationSeconds: Int, reason: String) {
    let timer = CookingTimer(name: name, durationSeconds: durationSeconds, reason: reason)
    timer.start()
    activeTimers.append(timer)
  }
  
  func removeTimer(_ timer: CookingTimer) {
    activeTimers.removeAll { $0.id == timer.id }
  }
  
  func clearCompletedTimers() {
    activeTimers.removeAll { $0.isFinished }
  }
  
  func addWarning(type: CookingWarningType, message: String) {
    let warning = CookingWarning(type: type, message: message, timestamp: Date())
    detectedWarnings.append(warning)
    // Keep only last 20 warnings
    if detectedWarnings.count > 20 {
      detectedWarnings.removeFirst()
    }
  }
  
  func clearWarning(id: UUID) {
    detectedWarnings.removeAll { $0.id == id }
  }
  
  func updateSceneDescription(_ description: String) {
    lastSceneDescription = description
  }
  
  func updateUserTranscript(_ transcript: String) {
    lastUserTranscript = transcript
  }
  
  func endSession() {
    currentRecipe = nil
    currentStepIndex = 0
    completedStepIds.removeAll()
    activeTimers.removeAll()
    detectedWarnings.removeAll()
    ingredientsReady.removeAll()
    sessionStartTime = nil
    isPaused = false
  }
}

// MARK: - Cooking Timer

@MainActor
class CookingTimer: ObservableObject, Identifiable {
  let id = UUID()
  let name: String
  let durationSeconds: Int
  let reason: String
  
  @Published var remainingSeconds: Int
  @Published var isRunning: Bool = false
  @Published var isFinished: Bool = false
  @Published var isPaused: Bool = false
  
  private var timerTask: Task<Void, Never>?
  private var pauseStartTime: Date?
  private var accumulatedPauseTime: TimeInterval = 0
  
  init(name: String, durationSeconds: Int, reason: String) {
    self.name = name
    self.durationSeconds = durationSeconds
    self.reason = reason
    self.remainingSeconds = durationSeconds
  }
  
  func start() {
    guard !isRunning else { return }
    isRunning = true
    isPaused = false
    accumulatedPauseTime = 0
    
    let startTime = Date()
    timerTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled && self.remainingSeconds > 0 {
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        guard !Task.isCancelled else { break }
        
        if !self.isPaused {
          await MainActor.run {
            self.remainingSeconds -= 1
            if self.remainingSeconds <= 0 {
              self.isFinished = true
              self.isRunning = false
            }
          }
        }
      }
    }
  }
  
  func pause() {
    guard isRunning, !isPaused else { return }
    isPaused = true
    pauseStartTime = Date()
  }
  
  func resume() {
    guard isRunning, isPaused else { return }
    isPaused = false
    if let pauseStart = pauseStartTime {
      accumulatedPauseTime += Date().timeIntervalSince(pauseStart)
    }
    pauseStartTime = nil
  }
  
  func cancel() {
    timerTask?.cancel()
    timerTask = nil
    isRunning = false
    isPaused = false
    isFinished = true
  }
  
  var formattedRemaining: String {
    let minutes = remainingSeconds / 60
    let seconds = remainingSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }
  
  var progress: Double {
    guard durationSeconds > 0 else { return 0 }
    return 1.0 - (Double(remainingSeconds) / Double(durationSeconds))
  }
}

// MARK: - Cooking Warning

enum CookingWarningType: String, Codable {
  case safety
  case quality
  case missingItem
  case uncertainty
}

struct CookingWarning: Identifiable, Equatable {
  let id = UUID()
  let type: CookingWarningType
  let message: String
  let timestamp: Date
}

// MARK: - CookClaw Response (Structured output from AI)

struct CookClawResponse: Codable {
  let currentStep: String
  let detectedState: String
  let confidence: Double
  let userInstruction: String
  let uiCard: String
  let nextExpectedAction: String
  let completedSteps: [String]
  let activeTimers: [TimerJSON]
  let warnings: [WarningJSON]
  let shouldInterrupt: Bool
  
  struct TimerJSON: Codable {
    let name: String
    let durationSeconds: Int
    let reason: String
  }
  
  struct WarningJSON: Codable {
    let type: String
    let message: String
  }
}

// MARK: - WebRTC Overlay Snapshot

/// A lightweight, serializable snapshot of the cooking session state
/// that can be sent over the WebRTC signaling WebSocket to render
/// a companion overlay on the web viewer.
struct WebRTCOverlaySnapshot: Codable {
  struct TimerSnapshot: Codable {
    let name: String
    let remainingSeconds: Int
    let isPaused: Bool
    let isFinished: Bool
  }

  struct WarningSnapshot: Codable {
    let type: String
    let message: String
  }

  struct StepSnapshot: Codable {
    let id: String
    let instruction: String
    let type: String  // "prep", "activeCooking", "waiting", "plating"
    let status: String // "pending", "current", "completed"
    let estimatedDurationSeconds: Int?
    let targetTemperature: String?
    let visualCue: String?
  }

  let recipeTitle: String?
  let stepInstruction: String?
  let visualCue: String?
  let targetTemperature: String?
  let progressText: String
  let isComplete: Bool
  let isPaused: Bool
  let activeTimers: [TimerSnapshot]
  let warnings: [WarningSnapshot]
  let steps: [StepSnapshot]
  let currentStepId: String?
}

extension WebRTCOverlaySnapshot {
  @MainActor
  init(from state: CookingSessionState) {
    self.recipeTitle = state.currentRecipe?.title
    self.stepInstruction = state.currentStep?.instruction
    self.visualCue = state.currentStep?.visualCue
    self.targetTemperature = state.currentStep?.targetTemperature
    self.progressText = Self.buildProgressText(state: state)
    self.isComplete = state.isComplete
    self.isPaused = state.isPaused
    self.currentStepId = state.currentStep?.id
    
    // Build all steps with their status
    if let recipe = state.currentRecipe {
      self.steps = recipe.steps.map { step in
        let status: String
        if state.completedStepIds.contains(step.id) {
          status = "completed"
        } else if step.id == state.currentStep?.id {
          status = "current"
        } else {
          status = "pending"
        }
        return StepSnapshot(
          id: step.id,
          instruction: step.instruction,
          type: step.type.rawValue,
          status: status,
          estimatedDurationSeconds: step.estimatedDurationSeconds,
          targetTemperature: step.targetTemperature,
          visualCue: step.visualCue
        )
      }
    } else {
      self.steps = []
    }
    
    self.activeTimers = state.activeTimers.map { timer in
      TimerSnapshot(
        name: timer.name,
        remainingSeconds: timer.remainingSeconds,
        isPaused: timer.isPaused,
        isFinished: timer.isFinished
      )
    }
    self.warnings = Array(state.detectedWarnings.suffix(3)).map { warning in
      WarningSnapshot(
        type: warning.type.rawValue,
        message: warning.message
      )
    }
  }

  @MainActor
  private static func buildProgressText(state: CookingSessionState) -> String {
    guard let recipe = state.currentRecipe else { return "" }
    let total = recipe.steps.count
    let done = state.completedStepIds.count
    let pct = Int(state.progressPercentage * 100)
    return "Step \(done)/\(total) • \(pct)%"
  }
}
