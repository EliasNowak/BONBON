import Foundation

/// Routes CookClaw-specific tool calls and manages cooking session state
@MainActor
class CookClawBridge: ObservableObject {
  @Published var cookingState = CookingSessionState()
  @Published var lastAIResponse: CookClawResponse?
  
  private let recipeParser = RecipeParser()
  private var toolCallRouter: ToolCallRouter?
  
  /// Process a tool call from Gemini and return the result
  func handleToolCall(
    _ call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    let callId = call.id
    let callName = call.name
    
    NSLog("[CookClaw] Tool call: %@ (id: %@) args: %@",
          callName, callId, String(describing: call.args))
    
    switch callName {
    case "execute":
      // Delegate to OpenClawBridge for non-cooking actions
      handleExecuteFallback(call: call, sendResponse: sendResponse)
      
    case "update_cooking_state":
      handleUpdateState(call: call, sendResponse: sendResponse)
      
    case "set_timer":
      handleSetTimer(call: call, sendResponse: sendResponse)
      
    case "cancel_timer":
      handleCancelTimer(call: call, sendResponse: sendResponse)
      
    case "detect_issue":
      handleDetectIssue(call: call, sendResponse: sendResponse)
      
    case "load_recipe":
      handleLoadRecipe(call: call, sendResponse: sendResponse)
      
    case "get_recipe_status":
      handleGetStatus(call: call, sendResponse: sendResponse)
      
    default:
      let result = ToolResult.failure("Unknown CookClaw tool: \(callName)")
      sendResponse(buildToolResponse(callId: callId, name: callName, result: result))
    }
  }
  
  // MARK: - Tool Handlers
  
  private func handleUpdateState(call: GeminiFunctionCall, sendResponse: @escaping ([String: Any]) -> Void) {
    guard let action = call.args["action"] as? String else {
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .failure("Missing 'action' parameter")
      ))
      return
    }
    
    switch action {
    case "complete_step":
      if let stepId = call.args["step_id"] as? String {
        cookingState.markStepComplete(id: stepId)
        // Also advance if it was the current step
        if cookingState.currentStep?.id == stepId {
          cookingState.advanceToNextStep()
        }
      } else {
        cookingState.completeCurrentStep()
      }
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .success("Step completed. Now at: \(cookingState.currentStep?.instruction ?? "Done!")")
      ))
      
    case "go_to_step":
      if let stepId = call.args["step_id"] as? String {
        cookingState.goToStep(id: stepId)
        sendResponse(buildToolResponse(
          callId: call.id,
          name: call.name,
          result: .success("Jumped to step \(stepId)")
        ))
      } else {
        sendResponse(buildToolResponse(
          callId: call.id,
          name: call.name,
          result: .failure("Missing 'step_id' for go_to_step")
        ))
      }
      
    case "mark_ingredient_ready":
      if let ingredient = call.args["ingredient_name"] as? String {
        cookingState.markIngredientReady(ingredient)
        sendResponse(buildToolResponse(
          callId: call.id,
          name: call.name,
          result: .success("Marked \(ingredient) as ready")
        ))
      } else {
        sendResponse(buildToolResponse(
          callId: call.id,
          name: call.name,
          result: .failure("Missing 'ingredient_name'")
        ))
      }
      
    case "pause":
      cookingState.pause()
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .success("Cooking session paused")
      ))
      
    case "resume":
      cookingState.resume()
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .success("Cooking session resumed")
      ))
      
    case "reset":
      cookingState.endSession()
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .success("Cooking session reset")
      ))
      
    default:
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .failure("Unknown action: \(action)")
      ))
    }
  }
  
  private func handleSetTimer(call: GeminiFunctionCall, sendResponse: @escaping ([String: Any]) -> Void) {
    guard let name = call.args["name"] as? String,
          let duration = call.args["duration_seconds"] as? Int else {
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .failure("Missing 'name' or 'duration_seconds'")
      ))
      return
    }
    
    let reason = call.args["reason"] as? String ?? "Cooking timer"
    cookingState.addTimer(name: name, durationSeconds: duration, reason: reason)
    
    sendResponse(buildToolResponse(
      callId: call.id,
      name: call.name,
      result: .success("Timer '\(name)' set for \(duration / 60) minutes")
    ))
  }
  
  private func handleCancelTimer(call: GeminiFunctionCall, sendResponse: @escaping ([String: Any]) -> Void) {
    guard let timerName = call.args["timer_name"] as? String else {
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .failure("Missing 'timer_name'")
      ))
      return
    }
    
    if let timer = cookingState.activeTimers.first(where: { $0.name == timerName }) {
      timer.cancel()
      cookingState.removeTimer(timer)
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .success("Timer '\(timerName)' cancelled")
      ))
    } else {
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .failure("Timer '\(timerName)' not found")
      ))
    }
  }
  
  private func handleDetectIssue(call: GeminiFunctionCall, sendResponse: @escaping ([String: Any]) -> Void) {
    guard let issueType = call.args["issue_type"] as? String,
          let message = call.args["message"] as? String else {
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .failure("Missing 'issue_type' or 'message'")
      ))
      return
    }
    
    let severity = call.args["severity"] as? String ?? "medium"
    let type = CookingWarningType(rawValue: issueType) ?? .uncertainty
    
    cookingState.addWarning(type: type, message: "[\(severity.uppercased())] \(message)")
    
    // If critical safety issue, mark as should interrupt
    let shouldInterrupt = type == .safety || severity == "critical"
    
    sendResponse(buildToolResponse(
      callId: call.id,
      name: call.name,
      result: .success("Issue logged: \(message). Interrupt: \(shouldInterrupt)")
    ))
  }
  
  private func handleLoadRecipe(call: GeminiFunctionCall, sendResponse: @escaping ([String: Any]) -> Void) {
    guard let recipeText = call.args["recipe_text"] as? String else {
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .failure("Missing 'recipe_text'")
      ))
      return
    }
    
    let title = call.args["title"] as? String ?? "Untitled Recipe"
    let recipe = RecipeParser.parseRecipeText(recipeText, title: title)
    
    cookingState.startRecipe(recipe)
    
    let summary = """
      Recipe loaded: \(recipe.title)
      Steps: \(recipe.steps.count)
      Prep: \(recipe.prepSteps.count)
      Cooking: \(recipe.activeCookingSteps.count)
      Waiting: \(recipe.waitingSteps.count)
      Plating: \(recipe.platingSteps.count)
      """
    
    sendResponse(buildToolResponse(
      callId: call.id,
      name: call.name,
      result: .success(summary)
    ))
  }
  
  private func handleGetStatus(call: GeminiFunctionCall, sendResponse: @escaping ([String: Any]) -> Void) {
    guard let recipe = cookingState.currentRecipe else {
      sendResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .success("No active recipe. Say 'load recipe' to start cooking.")
      ))
      return
    }
    
    let currentStep = cookingState.currentStep?.instruction ?? "All steps complete!"
    let progress = Int(cookingState.progressPercentage * 100)
    let timers = cookingState.activeTimers.map { "\($0.name): \($0.formattedRemaining)" }.joined(separator: ", ")
    
    let status = """
      Recipe: \(recipe.title) (\(progress)% complete)
      Current step: \(currentStep)
      Completed: \(cookingState.completedSteps.count)/\(recipe.steps.count)
      Active timers: \(timers.isEmpty ? "None" : timers)
      Ingredients ready: \(cookingState.ingredientsReady.count)/\(recipe.ingredients.count)
      """
    
    sendResponse(buildToolResponse(
      callId: call.id,
      name: call.name,
      result: .success(status)
    ))
  }
  
  // MARK: - Fallback to OpenClawBridge
  
  private func handleExecuteFallback(
    call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    // This would normally delegate to OpenClawBridge
    // For now, return a message suggesting this is a cooking session
    let task = call.args["task"] as? String ?? "unknown"
    sendResponse(buildToolResponse(
      callId: call.id,
      name: call.name,
      result: .success("Non-cooking task received: '\(task)'. In cooking mode, I focus on recipe guidance. For other tasks, exit cooking mode first.")
    ))
  }
  
  // MARK: - Helpers
  
  private func buildToolResponse(
    callId: String,
    name: String,
    result: ToolResult
  ) -> [String: Any] {
    return [
      "toolResponse": [
        "functionResponses": [
          [
            "id": callId,
            "name": name,
            "response": result.responseValue
          ]
        ]
      ]
    ]
  }
}
