import Foundation

/// Parses raw recipe text or structured formats into atomic Recipe objects
@MainActor
class RecipeParser {
  
  /// Parse a plain text recipe into structured steps
  static func parseRecipeText(_ text: String, title: String = "Untitled Recipe") -> Recipe {
    let lines = text.components(separatedBy: .newlines)
    var ingredients: [Ingredient] = []
    var steps: [RecipeStep] = []
    var section: String = ""
    var stepNumber = 0
    
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      
      // Detect sections
      if trimmed.lowercased().contains("ingredient") {
        section = "ingredients"
        continue
      }
      if trimmed.lowercased().contains("instruction") || trimmed.lowercased().contains("direction") || trimmed.lowercased().contains("step") {
        section = "steps"
        continue
      }
      
      if section == "ingredients" {
        let ingredient = parseIngredientLine(trimmed)
        ingredients.append(ingredient)
      } else if section == "steps" {
        stepNumber += 1
        let step = parseStepLine(trimmed, stepNumber: stepNumber)
        steps.append(step)
      }
    }
    
    // If no sections detected, treat all non-empty lines as steps
    if steps.isEmpty && !lines.isEmpty {
      var lineNum = 0
      for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        lineNum += 1
        steps.append(parseStepLine(trimmed, stepNumber: lineNum))
      }
    }
    
    return Recipe(
      title: title,
      totalTimeMinutes: nil,
      servings: nil,
      source: nil,
      ingredients: ingredients,
      steps: steps,
      tags: []
    )
  }
  
  /// Parse structured recipe from a hypothetical API or JSON
  static func parseStructuredRecipe(_ json: [String: Any]) -> Recipe? {
    guard let title = json["title"] as? String else { return nil }
    
    let ingredients: [Ingredient] = (json["ingredients"] as? [[String: Any]])?.compactMap { ingJson in
      guard let name = ingJson["name"] as? String else { return nil }
      return Ingredient(
        name: name,
        quantity: ingJson["quantity"] as? String,
        preparation: ingJson["preparation"] as? String,
        isOptional: ingJson["optional"] as? Bool ?? false,
        isChecked: false
      )
    } ?? []
    
    let steps: [RecipeStep] = (json["steps"] as? [[String: Any]])?.enumerated().compactMap { index, stepJson in
      guard let instruction = stepJson["instruction"] as? String else { return nil }
      return RecipeStep(
        id: "step_\(index + 1)",
        type: stepType(from: stepJson["type"] as? String),
        instruction: instruction,
        estimatedDurationSeconds: stepJson["duration_seconds"] as? Int,
        targetTemperature: stepJson["temperature"] as? String,
        visualCue: stepJson["visual_cue"] as? String,
        safetyNote: stepJson["safety"] as? String,
        dependsOnStepIds: stepJson["depends_on"] as? [String] ?? [],
        isOptional: stepJson["optional"] as? Bool ?? false
      )
    } ?? []
    
    return Recipe(
      title: title,
      totalTimeMinutes: json["total_time_minutes"] as? Int,
      servings: json["servings"] as? Int,
      source: json["source"] as? String,
      ingredients: ingredients,
      steps: steps,
      tags: json["tags"] as? [String] ?? []
    )
  }
  
  // MARK: - Private
  
  private static func parseIngredientLine(_ line: String) -> Ingredient {
    // Simple heuristic: look for numbers at start
    let quantityPattern = try? NSRegularExpression(pattern: "^([0-9/.\\s]+(?:cups?|tbsp|tsp|oz|lbs?|g|kg|ml|l|pieces?|cloves?|pinch|dash)?)\\s*(.*)", options: .caseInsensitive)
    
    if let regex = quantityPattern {
      let range = NSRange(line.startIndex..., in: line)
      if let match = regex.firstMatch(in: line, options: [], range: range) {
        let quantityRange = Range(match.range(at: 1), in: line)
        let nameRange = Range(match.range(at: 2), in: line)
        let quantity = quantityRange.map { String(line[$0]).trimmingCharacters(in: .whitespaces) }
        let name = nameRange.map { String(line[$0]).trimmingCharacters(in: .whitespaces) } ?? line
        
        // Extract preparation hints
        var prep: String?
        if name.contains(",") {
          let parts = name.components(separatedBy: ",")
          prep = parts.last?.trimmingCharacters(in: .whitespaces)
        }
        
        return Ingredient(
          name: name,
          quantity: quantity,
          preparation: prep,
          isOptional: line.lowercased().contains("optional") || line.contains("*"),
          isChecked: false
        )
      }
    }
    
    return Ingredient(name: line, quantity: nil, preparation: nil, isOptional: false, isChecked: false)
  }
  
  private static func parseStepLine(_ line: String, stepNumber: Int) -> RecipeStep {
    let lowercased = line.lowercased()
    
    // Infer step type from content
    let type: RecipeStepType
    if lowercased.contains("serve") || lowercased.contains("plate") || lowercased.contains("garnish") {
      type = .plating
    } else if lowercased.contains("wait") || lowercased.contains("let rest") || lowercased.contains("simmer") || lowercased.contains("bake") || lowercased.contains("roast") || lowercased.contains("for") && containsTimeHint(lowercased) {
      type = .waiting
    } else if lowercased.contains("heat") || lowercased.contains("cook") || lowercased.contains("fry") || lowercased.contains("sauté") || lowercased.contains("boil") || lowercased.contains("grill") || lowercased.contains("stir") {
      type = .activeCooking
    } else {
      type = .prep
    }
    
    // Extract duration hints
    var duration: Int?
    if let minutes = extractMinutes(from: line) {
      duration = minutes * 60
    } else if let seconds = extractSeconds(from: line) {
      duration = seconds
    }
    
    // Extract temperature hints
    var temperature: String?
    if lowercased.contains("°f") || lowercased.contains("°c") || lowercased.contains("fahrenheit") || lowercased.contains("celsius") {
      temperature = extractTemperature(from: line)
    } else if lowercased.contains("medium") || lowercased.contains("high heat") || lowercased.contains("low heat") {
      temperature = extractHeatLevel(from: line)
    }
    
    // Extract visual cues
    var visualCue: String?
    let visualKeywords = ["golden", "brown", "translucent", "bubbling", "simmering", "crispy", "tender", "opaque"]
    for keyword in visualKeywords {
      if lowercased.contains(keyword) {
        visualCue = keyword
        break
      }
    }
    
    // Extract safety notes
    var safetyNote: String?
    let safetyKeywords = ["hot oil", "sharp", "raw", "knife", "burn", "boiling water", "steam"]
    for keyword in safetyKeywords {
      if lowercased.contains(keyword) {
        safetyNote = keyword
        break
      }
    }
    
    return RecipeStep(
      id: "step_\(stepNumber)",
      type: type,
      instruction: line,
      estimatedDurationSeconds: duration,
      targetTemperature: temperature,
      visualCue: visualCue,
      safetyNote: safetyNote,
      dependsOnStepIds: [],
      isOptional: false
    )
  }
  
  private static func stepType(from string: String?) -> RecipeStepType {
    guard let string = string?.lowercased() else { return .prep }
    switch string {
    case "active_cooking", "cooking", "cook": return .activeCooking
    case "waiting", "timer", "rest": return .waiting
    case "plating", "serve", "finish": return .plating
    default: return .prep
    }
  }
  
  private static func containsTimeHint(_ text: String) -> Bool {
    let timePattern = try? NSRegularExpression(pattern: "\\b\\d+\\s*(minutes?|mins?|seconds?|secs?|hours?|hrs?)\\b", options: .caseInsensitive)
    let range = NSRange(text.startIndex..., in: text)
    return timePattern?.firstMatch(in: text, options: [], range: range) != nil
  }
  
  private static func extractMinutes(from text: String) -> Int? {
    let pattern = try? NSRegularExpression(pattern: "(\\d+)\\s*(minutes?|mins?)", options: .caseInsensitive)
    let range = NSRange(text.startIndex..., in: text)
    guard let match = pattern?.firstMatch(in: text, options: [], range: range),
          let numRange = Range(match.range(at: 1), in: text),
          let num = Int(text[numRange]) else { return nil }
    return num
  }
  
  private static func extractSeconds(from text: String) -> Int? {
    let pattern = try? NSRegularExpression(pattern: "(\\d+)\\s*(seconds?|secs?)", options: .caseInsensitive)
    let range = NSRange(text.startIndex..., in: text)
    guard let match = pattern?.firstMatch(in: text, options: [], range: range),
          let numRange = Range(match.range(at: 1), in: text),
          let num = Int(text[numRange]) else { return nil }
    return num
  }
  
  private static func extractTemperature(from text: String) -> String? {
    let pattern = try? NSRegularExpression(pattern: "(\\d+)\\s*°?\\s*(F|C|fahrenheit|celsius)", options: .caseInsensitive)
    let range = NSRange(text.startIndex..., in: text)
    guard let match = pattern?.firstMatch(in: text, options: [], range: range),
          let numRange = Range(match.range(at: 1), in: text),
          let unitRange = Range(match.range(at: 2), in: text) else { return nil }
    return text[numRange] + "°" + text[unitRange].uppercased()
  }
  
  private static func extractHeatLevel(from text: String) -> String? {
    let levels = ["medium-high", "medium low", "medium", "high", "low", "simmer"]
    let lowercased = text.lowercased()
    for level in levels {
      if lowercased.contains(level) {
        return level.capitalized + " heat"
      }
    }
    return nil
  }
}
