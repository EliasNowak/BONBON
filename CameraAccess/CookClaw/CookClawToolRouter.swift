import Foundation

/// Routes tool calls in CookClaw mode: delegates cooking tools to CookClawBridge, non-cooking to OpenClawBridge
@MainActor
class CookClawToolRouter {
  private let cookClawBridge: CookClawBridge
  private let openClawBridge: OpenClawBridge
  private var inFlightTasks: [String: Task<Void, Never>] = [:]
  private var consecutiveFailures = 0
  private let maxConsecutiveFailures = 3
  private(set) var lastToolCallStatus: ToolCallStatus = .idle

  init(cookClawBridge: CookClawBridge, openClawBridge: OpenClawBridge) {
    self.cookClawBridge = cookClawBridge
    self.openClawBridge = openClawBridge
  }

  /// Route a tool call. Cooking tools go to CookClawBridge, everything else to OpenClawBridge.
  func handleToolCall(
    _ call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    let callId = call.id
    let callName = call.name

    NSLog("[CookClawToolRouter] Received: %@ (id: %@)", callName, callId)

    // Circuit breaker
    if consecutiveFailures >= maxConsecutiveFailures {
      lastToolCallStatus = .failed(callName, "Circuit breaker open")
      let errorResult: ToolResult = .failure(
        "Tool execution temporarily unavailable after \(consecutiveFailures) consecutive failures."
      )
      sendResponse(buildToolResponse(callId: callId, name: callName, result: errorResult))
      return
    }

    lastToolCallStatus = .executing(callName)

    let task = Task { @MainActor in
      let result = await self.executeToolCall(call)

      guard !Task.isCancelled else {
        NSLog("[CookClawToolRouter] Task %@ cancelled", callId)
        return
      }

      switch result {
      case .success:
        self.consecutiveFailures = 0
        self.lastToolCallStatus = .completed(callName)
      case .failure:
        self.consecutiveFailures += 1
        self.lastToolCallStatus = .failed(callName, result.errorMessage ?? "Unknown error")
      }

      let response = self.buildToolResponse(callId: callId, name: callName, result: result)
      sendResponse(response)
      self.inFlightTasks.removeValue(forKey: callId)
    }

    inFlightTasks[callId] = task
  }

  func cancelToolCalls(ids: [String]) {
    for id in ids {
      if let task = inFlightTasks[id] {
        NSLog("[CookClawToolRouter] Cancelling: %@", id)
        task.cancel()
        inFlightTasks.removeValue(forKey: id)
      }
    }
    lastToolCallStatus = .cancelled(ids.first ?? "unknown")
  }

  func cancelAll() {
    for (id, task) in inFlightTasks {
      NSLog("[CookClawToolRouter] Cancelling: %@", id)
      task.cancel()
    }
    inFlightTasks.removeAll()
    consecutiveFailures = 0
    lastToolCallStatus = .idle
  }

  // MARK: - Private

  private func executeToolCall(_ call: GeminiFunctionCall) async -> ToolResult {
    switch call.name {
    case "execute":
      // Non-cooking actions delegate to OpenClawBridge
      let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
      return await openClawBridge.delegateTask(task: taskDesc, toolName: call.name)

    case "update_cooking_state", "set_timer", "cancel_timer",
         "detect_issue", "load_recipe", "get_recipe_status":
      // Cooking-specific tools handled by CookClawBridge
      return await withCheckedContinuation { continuation in
        cookClawBridge.handleToolCall(call) { response in
          // Extract result from the response
          if let toolResponse = response["toolResponse"] as? [String: Any],
             let functionResponses = toolResponse["functionResponses"] as? [[String: Any]],
             let first = functionResponses.first,
             let resp = first["response"] as? [String: Any] {
            if let result = resp["result"] as? String {
              continuation.resume(returning: .success(result))
            } else if let error = resp["error"] as? String {
              continuation.resume(returning: .failure(error))
            } else {
              continuation.resume(returning: .success("OK"))
            }
          } else {
            continuation.resume(returning: .failure("Invalid response format"))
          }
        }
      }

    default:
      return .failure("Unknown tool: \(call.name)")
    }
  }

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

private extension ToolResult {
  var errorMessage: String? {
    if case .failure(let error) = self {
      return error
    }
    return nil
  }
}
