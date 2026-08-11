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

/// A capability that can be offered to a language model session, allowing
/// the model to activate specialized behavior on demand.
///
/// A skill pairs a name and description (visible to the model) with either
/// a Prompt or a string instructions payload that takes effect when
/// the model activates it. In both cases the model activates a skill by
/// generating a tool call.
///
/// ## Prompt-based skills
///
/// When you initialize a skill with a trailing `@PromptBuilder`, the
/// skill's content is added to the transcript as part of the matching tool
/// output. This has the advantage of not invalidating the key-value cache.
///
/// ```swift
/// Skill(
///     name: "style-guide",
///     description: "Applies the project's writing style guide"
/// ) {
///     """
///     # Style Guide
///
///     ## Keep phrasing literal
///     Idioms and figurative phrases can add color, but they slow down
///     readers who are scanning, learning the language, or translating.
///
///     ...(continued)
///     """
/// }
/// ```
///
/// ## Instructions-based skills
///
/// When you initialize a skill with an `instructions` string, the
/// skill's content is inserted into the instructions entry at the top of
/// the transcript. Models are typically trained to obey instructions with
/// high priority, but activating an instructions-based skill often comes
/// at the cost of a key-value cache invalidation.
///
/// ```swift
/// Skill(
///     name: "calendaring",
///     description: "Read and modify the user's calendar",
///     instructions: "Unless specified otherwise, all work meetings "
///         + "should start 5 minutes after the hour.",
///     allowsDeactivation: true
/// )
/// ```
///
/// Instructions-based skills can optionally be deactivated by the model
/// after activation, which can help combat context pollution.
public struct Skill {
  var name: String { storage.name }

  var description: String { storage.description }

  func activate() { storage.onActivate() }

  func deactivate() {
    if case .instructions(let skill) = storage {
      skill.onDeactivate()
    }
  }

  let storage: Storage

  enum Storage {
    case prompt(PromptSkill)
    case instructions(InstructionsSkill)

    var name: String {
      switch self {
      case .prompt(let skill): skill.name
      case .instructions(let skill): skill.name
      }
    }

    var description: String {
      switch self {
      case .prompt(let skill): skill.description
      case .instructions(let skill): skill.description
      }
    }

    var onActivate: @Sendable () -> Void {
      switch self {
      case .prompt(let skill): skill.onActivate
      case .instructions(let skill): skill.onActivate
      }
    }
  }

  // MARK: - Prompt-based initializers

  /// Creates a prompt-based skill from a string.
  ///
  /// When the model activates this skill, the prompt is injected into the
  /// conversation as additional context.
  ///
  /// - Parameters:
  ///   - name: A short, unique name the model uses to identify this skill.
  ///   - description: A human-readable explanation of what the skill does,
  ///     shown to the model so it can decide when to activate it.
  ///   - prompt: The prompt content delivered to the model upon activation.
  ///   - onActivate: A closure invoked each time the model activates this
  ///     skill. Defaults to a no-op.
  public init(
    name: String,
    description: String,
    prompt: String,
    onActivate: @Sendable @escaping () -> Void = {}
  ) {
    self.init(
      name: name,
      description: description,
      onActivate: onActivate
    ) {
      Prompt { prompt }
    }
  }

  /// Creates a prompt-based skill using a `PromptBuilder`.
  public init(
    name: String,
    description: String,
    onActivate: @Sendable @escaping () -> Void = {},
    @PromptBuilder prompt: () -> Prompt,
  ) {
    storage = .prompt(
      PromptSkill(
        name: name,
        description: description,
        prompt: prompt(),
        onActivate: onActivate
      )
    )
  }

  // MARK: - Instructions-based initializers

  /// Creates an instructions-based skill.
  ///
  /// Unlike prompt-based skills, instructions-based skills inject
  /// content into the instructions entry that persists while the skill
  /// is active. They can optionally be toggled on and off by the model.
  ///
  /// - Parameters:
  ///   - name: A short, unique name the model uses to identify this skill.
  ///   - description: A human-readable explanation of what the skill does.
  ///   - instructions: The instructions text applied while the skill is
  ///     active.
  ///   - allowsDeactivation: Whether the model is permitted to deactivate
  ///     this skill after it has been activated.
  ///   - onActivate: A closure invoked each time the model activates this
  ///     skill.
  ///   - onDeactivate: A closure invoked each time the model deactivates
  ///     this skill.
  public init(
    name: String,
    description: String,
    instructions: InstructionsRepresentable,
    allowsDeactivation: Bool = false,
    onActivate: @Sendable @escaping () -> Void = {},
    onDeactivate: @Sendable @escaping () -> Void = {}
  ) {
    storage = .instructions(
      InstructionsSkill(
        name: name,
        description: description,
        instructions: AnyDynamicInstructions(Instructions(instructions)),
        allowsDeactivation: allowsDeactivation,
        onActivate: onActivate,
        onDeactivate: onDeactivate
      )
    )
  }

  /// Creates an instructions-based skill using a `DynamicInstructionsBuilder`.
  ///
  /// Use this initializer to compose the skill's instructions declaratively.
  /// The closure may include [`Instructions`](https://developer.apple.com/documentation/FoundationModels/Instructions) content as well as [`Tool`](https://developer.apple.com/documentation/FoundationModels/Tool)
  /// values; while the skill is active, its instructions are injected into
  /// the instructions entry and any tools it carries become available to the
  /// model. Instructions-based skills can optionally be toggled on and off by
  /// the model.
  ///
  /// - Parameters:
  ///   - name: A short, unique name the model uses to identify this skill.
  ///   - description: A human-readable explanation of what the skill does.
  ///   - allowsDeactivation: Whether the model is permitted to deactivate
  ///     this skill after it has been activated.
  ///   - onActivate: A closure invoked each time the model activates this
  ///     skill.
  ///   - onDeactivate: A closure invoked each time the model deactivates
  ///     this skill.
  ///   - instructions: The instructions, and any tools, applied while the
  ///     skill is active.
  public init(
    name: String,
    description: String,
    allowsDeactivation: Bool = false,
    onActivate: @Sendable @escaping () -> Void = {},
    onDeactivate: @Sendable @escaping () -> Void = {},
    @DynamicInstructionsBuilder instructions: () -> some DynamicInstructions
  ) {
    storage = .instructions(
      InstructionsSkill(
        name: name,
        description: description,
        instructions: AnyDynamicInstructions(instructions()),
        allowsDeactivation: allowsDeactivation,
        onActivate: onActivate,
        onDeactivate: onDeactivate
      )
    )
  }
}

struct InstructionsSkill {
  let name: String
  let description: String
  let instructions: AnyDynamicInstructions
  let allowsDeactivation: Bool
  let onActivate: @Sendable () -> Void
  let onDeactivate: @Sendable () -> Void
}

struct PromptSkill {
  let name: String
  let description: String
  let prompt: Prompt
  let onActivate: @Sendable () -> Void
}
