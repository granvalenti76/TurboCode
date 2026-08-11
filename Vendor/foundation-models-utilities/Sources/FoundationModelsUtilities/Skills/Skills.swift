//===----------------------------------------------------------------------===//
//
// This source file is part of the Foundation Models open source project.
//
// Copyright © 2024-2027 Apple Inc. and the Foundation Models project authors.
//
// Licensed under the Apache License v2.0
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//
public import FoundationModels

/// A dynamic instructions component that manages a collection of `Skill`
/// values, exposing them to the model as a tool it can call to toggle
/// individual skills on and off.
///
/// `Skills` generates a tool (named `toggle_skill` or `activate_skill` by
/// default) whose schema lists the available skill names. When the model
/// calls the tool, the corresponding skill is activated or deactivated and
/// its instructions or prompt are injected into the session.
///
/// ```swift
/// Skills(activations: activations) {
///     Skill(
///         name: "style-guide",
///         description: "Applies the project's writing style guide"
///     ) {
///         """
///         # Style Guide
///
///         ## Keep phrasing literal
///         Idioms and figurative phrases can add color, but they slow down
///         readers who are scanning, learning the language, or translating.
///
///         ...(continued)
///         """
///     }
///
///     Skill(
///         name: "calendaring",
///         description: "Read and modify the user's calendar"
///     ) {
///         Instructions(
///             "Unless specified otherwise, all work meetings should "
///             + "start 5 minutes after the hour"
///         )
///         QueryCalendarEventsTool()
///         AddCalendarEventTool()
///         DeleteCalendarEventTool()
///         ModifyCalendarEventTool()
///     }
/// }
/// ```
public struct Skills: DynamicInstructions {
  /// The default leading instructions rendered above the list of skills.
  private static let defaultInstructions = Instructions {
    """
    If a skill below fits the user's request, silently activate it before \
    responding. Otherwise, respond normally without calling tools.
    """
  }

  private let toolName: String?

  private let toolDescription: String?

  private let instructions: Instructions

  private let skills: [Skill]

  private let strictSchema: Bool

  private let activations: SkillActivations

  /// Creates a skills container using a result-builder closure.
  ///
  /// - Parameters:
  ///   - activations: The ``SkillActivations`` instance that tracks
  ///     which skills are currently active.
  ///   - toolName: A custom name for the tool exposed to the model.
  ///     Defaults to `"toggle_skill"` or `"activate_skill"` depending on
  ///     whether any skill allows deactivation.
  ///   - toolDescription: A custom description for the tool exposed to the
  ///     model. When `nil`, a default description is generated.
  ///   - instructions: The leading instructions rendered above the list of
  ///     skills. When `nil`, a default instruction is used.
  ///   - strictSchema: When `true`, the tool schema only lists skills that
  ///     are valid targets for the current toggle direction, preventing the
  ///     model from deactivating already-inactive skills or vice versa.
  ///   - skills: A ``SkillsBuilder`` closure that produces the array of
  ///     skills to manage.
  public init(
    activations: SkillActivations,
    toolName: String? = nil,
    toolDescription: String? = nil,
    instructions: Instructions? = nil,
    strictSchema: Bool = false,
    @SkillsBuilder skills: () -> [Skill]
  ) {
    self.init(
      activations: activations,
      toolName: toolName,
      toolDescription: toolDescription,
      instructions: instructions,
      strictSchema: strictSchema,
      skills: skills()
    )
  }

  /// Creates a skills container from an array of skills.
  ///
  /// - Parameters:
  ///   - activations: The ``SkillActivations`` instance that tracks
  ///     which skills are currently active.
  ///   - toolName: A custom name for the tool exposed to the model.
  ///     Defaults to `"toggle_skill"` or `"activate_skill"` depending on
  ///     whether any skill allows deactivation.
  ///   - toolDescription: A custom description for the tool exposed to the
  ///     model. When `nil`, a default description is generated.
  ///   - instructions: The leading instructions rendered above the list of
  ///     skills. When `nil`, a default instruction is used.
  ///   - strictSchema: When `true`, the tool schema only lists skills that
  ///     are valid targets for the current toggle direction, preventing the
  ///     model from deactivating already-inactive skills or vice versa.
  ///   - skills: The array of skills to manage.
  public init(
    activations: SkillActivations,
    toolName: String? = nil,
    toolDescription: String? = nil,
    instructions: Instructions? = nil,
    strictSchema: Bool = false,
    skills: [Skill]
  ) {
    self.activations = activations
    self.toolName = toolName
    self.toolDescription = toolDescription
    self.instructions = instructions ?? Skills.defaultInstructions
    self.skills = skills
    self.strictSchema = strictSchema
  }

  /// The dynamic instructions body that renders each skill's status and
  /// provides the toggle tool to the model.
  public var body: some DynamicInstructions {

    instructions

    DynamicInstructions.ForEach(Array(skills.enumerated()), id: \.element.name) { item in
      // Each skill is preceded by a blank line so the leading instruction and
      // every skill block are visually separated.
      let skill = item.element
      if case .instructions(let stored) = skill.storage {
        // Instructions-based skills carry persistent state, so the model is
        // shown whether each one is currently active or inactive.
        if activations.isActive(skill.name) {
          Instructions {
            "\nSkill: \(skill.name) [active]"
          }
          stored.instructions
        } else {
          Instructions {
            "\nSkill: \(skill.name) [inactive]"
            "Description: \(skill.description)"
          }
        }
      } else {
        // Prompt-based skills are one-shot: invoking one injects its content
        // as tool output rather than toggling a persistent mode. We label them
        // as on-demand so the model isn't told they're "inactive" after it has
        // already invoked them.
        Instructions {
          "\nSkill: \(skill.name) [on demand]"
          "Description: \(skill.description)"
        }
      }
    }

    ToggleSkillTool(
      name: toolName,
      description: toolDescription,
      skills: skills,
      activations: activations,
      strictSchema: strictSchema,
      onCall: { [activations] skill in
        switch skill.storage {
        case .prompt:
          // On-demand: fire the activation callback, but don't track the skill
          // as active — there's no persistent state to toggle off later.
          skill.activate()
        case .instructions:
          if activations.isActive(skill.name) {
            activations.deactivate(skill.name)
            skill.deactivate()
          } else {
            activations.activate(skill.name)
            skill.activate()
          }
        }
      }
    )
  }
}

private struct ToggleSkillTool: @unchecked Sendable, Tool {
  let name: String
  let description: String
  let parameters: GenerationSchema
  let onCall: @Sendable (Skill) -> Void
  let skills: [Skill]
  let activations: SkillActivations

  init(
    name: String?,
    description: String?,
    skills: [Skill],
    activations: SkillActivations,
    strictSchema: Bool,
    onCall: @Sendable @escaping (Skill) -> Void
  ) {
    let allowsDeactivation = skills.lazy.compactMap({ skill in
      if case .instructions(let stored) = skill.storage {
        return stored
      }
      return nil
    }).contains(where: \.allowsDeactivation)

    let activeNames = Set(activations.activeSkillNames)

    var allowed =
      skills
      .map(\.name)
      .filter { !activeNames.contains($0) }

    if !strictSchema || allowsDeactivation {
      allowed += activeNames
    }
    allowed.sort()

    let resolvedName = name ?? (allowsDeactivation ? "toggle_skill" : "activate_skill")

    let hasOnDemandSkill = skills.contains { skill in
      if case .prompt = skill.storage {
        return true
      }
      return false
    }

    // Include an explanation for "[on demand]" which appears in the instructions
    let onDemandExplanation: String? =
      if hasOnDemandSkill {
        """
        Skills marked [on demand] aren't toggled on or off; calling this tool \
        on one delivers its guidance once.
        """
      } else {
        nil
      }
    let defaultDescription =
      if allowsDeactivation {
        "Activate or deactivate a skill yourself when the user's request matches its description, and otherwise respond normally without calling this tool. Don't ask the user for permission to activate, and don't mention activation in your response."
          + (onDemandExplanation.map { " \($0)" } ?? "")
      } else {
        "Activate a skill yourself when the user's request matches its description, and otherwise respond normally without calling this tool. Don't ask the user for permission to activate, and don't mention activation in your response."
          + (onDemandExplanation.map { " \($0)" } ?? "")
      }
    let resolvedDescription = description ?? defaultDescription

    let parameters = try! GenerationSchema(
      root: DynamicGenerationSchema(
        name: "Arguments",
        properties: [
          DynamicGenerationSchema.Property(
            name: "skill",
            schema: DynamicGenerationSchema(
              type: String.self,
              guides: [.anyOf(allowed)]
            ),
          )
        ]
      ),
      dependencies: []
    )

    self.name = resolvedName
    self.description = resolvedDescription
    self.onCall = onCall
    self.parameters = parameters
    self.skills = skills
    self.activations = activations
  }

  func call(arguments: GeneratedContent) async throws -> Prompt {
    let name = try arguments.value(String.self, forProperty: "skill")

    guard let skill = skills.first(where: { $0.name == name }) else {
      throw GeneratedContent.ParsingError(
        rawContent: arguments.jsonString,
        debugDescription: """
          Model attempted to toggle a skill named '\(name)', \
          but no matching skill was found.

          Available skills:
          \(skills.map(\.name).joined(separator: "\n"))
          """
      )
    }

    defer { onCall(skill) }

    switch skill.storage {
    case .prompt(let promptSkill):
      return promptSkill.prompt
    case .instructions:
      let activated = activations.isActive(skill.name)
      let verb = activated ? "deactivated" : "activated"
      return Prompt { "Successfully \(verb) skill: \(skill.name)" }
    }
  }
}
