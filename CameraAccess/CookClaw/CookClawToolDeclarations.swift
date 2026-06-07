import Foundation

/// CookClaw-specific tool declarations for Gemini to call during cooking sessions
/// These extend the generic "execute" tool with cooking-aware capabilities
class CookClawToolDeclarations {
  
  /// All tool declarations available in cooking mode
  static func allDeclarations() -> [[String: Any]] {
    return [
      execute,
      updateCookingState,
      setTimer,
      cancelTimer,
      detectIssue,
      loadRecipe,
      getRecipeStatus
    ]
  }
  
  // MARK: - Generic execute (fallback for non-cooking actions)
  
  static let execute: [String: Any] = [
    "name": "execute",
    "description": "Use for non-cooking actions only: sending messages, web search, general questions, or anything outside the kitchen. For recipe steps, timers, or cooking state, use the cooking-specific tools instead.",
    "parameters": [
      "type": "object",
      "properties": [
        "task": [
          "type": "string",
          "description": "Clear description of what to do."
        ]
      ],
      "required": ["task"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
  
  // MARK: - Update Cooking State
  
  static let updateCookingState: [String: Any] = [
    "name": "update_cooking_state",
    "description": "Update the cooking session progress. Call this whenever you detect the user has completed a step, moved to a new step, or when scene analysis reveals state changes. Also call when the user asks to skip, repeat, or jump steps.",
    "parameters": [
      "type": "object",
      "properties": [
        "action": [
          "type": "string",
          "enum": ["complete_step", "go_to_step", "mark_ingredient_ready", "pause", "resume", "reset"],
          "description": "The state change action to perform."
        ],
        "step_id": [
          "type": "string",
          "description": "Step identifier for complete_step or go_to_step."
        ],
        "ingredient_name": [
          "type": "string",
          "description": "Ingredient name for mark_ingredient_ready."
        ]
      ],
      "required": ["action"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
  
  // MARK: - Timer Management
  
  static let setTimer: [String: Any] = [
    "name": "set_timer",
    "description": "Set a cooking timer with a name, duration, and reason. Use when a recipe step mentions a time duration (e.g., 'simmer for 10 minutes', 'let rest 5 minutes', 'bake for 25 minutes'). Always confirm verbally before calling.",
    "parameters": [
      "type": "object",
      "properties": [
        "name": [
          "type": "string",
          "description": "Short timer name, e.g., 'Pasta boil', 'Chicken rest'."
        ],
        "duration_seconds": [
          "type": "integer",
          "description": "Timer duration in seconds."
        ],
        "reason": [
          "type": "string",
          "description": "Why this timer exists, e.g., 'Pasta needs to boil for 10 minutes until al dente'."
        ]
      ],
      "required": ["name", "duration_seconds", "reason"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
  
  static let cancelTimer: [String: Any] = [
    "name": "cancel_timer",
    "description": "Cancel an active cooking timer by name. Use when the user says they're done early or made a mistake.",
    "parameters": [
      "type": "object",
      "properties": [
        "timer_name": [
          "type": "string",
          "description": "Name of the timer to cancel."
        ]
      ],
      "required": ["timer_name"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
  
  // MARK: - Issue Detection
  
  static let detectIssue: [String: Any] = [
    "name": "detect_issue",
    "description": "Report a cooking issue or warning detected from visual or audio analysis. Use when you see burning, undercooking, wrong ingredients, safety hazards, or any quality problem. This triggers immediate user alerts.",
    "parameters": [
      "type": "object",
      "properties": [
        "issue_type": [
          "type": "string",
          "enum": ["safety", "quality", "missing_item", "uncertainty"],
          "description": "Type of issue detected."
        ],
        "message": [
          "type": "string",
          "description": "Clear warning message for the user."
        ],
        "severity": [
          "type": "string",
          "enum": ["low", "medium", "high", "critical"],
          "description": "How urgent the issue is."
        ]
      ],
      "required": ["issue_type", "message"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
  
  // MARK: - Recipe Loading
  
  static let loadRecipe: [String: Any] = [
    "name": "load_recipe",
    "description": "Load a new recipe into the cooking session. Call when the user asks to cook something, provides a recipe text, or wants to switch recipes. This resets the cooking state and parses the recipe into trackable steps.",
    "parameters": [
      "type": "object",
      "properties": [
        "recipe_text": [
          "type": "string",
          "description": "The full recipe text provided by the user. Will be parsed into steps."
        ],
        "title": [
          "type": "string",
          "description": "Recipe title if known."
        ]
      ],
      "required": ["recipe_text"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
  
  // MARK: - Recipe Status Query
  
  static let getRecipeStatus: [String: Any] = [
    "name": "get_recipe_status",
    "description": "Get current cooking session status: current step, completed steps, active timers, ingredients, progress percentage. Call when the user asks 'where are we', 'what's next', or 'how much longer'.",
    "parameters": [
      "type": "object",
      "properties": [:]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
}
