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

/// A result builder that composes an array of `Skill` values using a
/// declarative syntax.
///
/// You don't use `SkillsBuilder` directly. Instead, pass a closure to
/// ``Skills/init(activations:toolName:toolDescription:strictSchema:skills:)-(_,_,_,_,()->[Skill])``
/// and the builder is applied automatically:
///
/// ```swift
/// Skills(activations: myActivations) {
///     Skill(
///         name: "style-guide",
///         description: "Applies the project's writing style guide",
///         prompt: "# Style Guide\n..."
///     )
///
///     if enableCalendaring {
///         Skill(
///             name: "calendaring",
///             description: "Read and modify the user's calendar",
///             instructions: "Unless specified otherwise, all work meetings "
///                 + "should start 5 minutes after the hour"
///         )
///     }
/// }
/// ```
///
/// The builder supports `if`/`else` branches, optional expressions,
/// and `for`-`in` loops.
@resultBuilder
public struct SkillsBuilder {
  /// Combines partial results from each statement in the builder body
  /// into a single array of skills.
  public static func buildBlock(_ components: [Skill]...) -> [Skill] {
    components.flatMap({ $0 })
  }

  /// Converts a single ``Skill`` expression into the builder's partial
  /// result type.
  public static func buildExpression(_ expression: Skill) -> [Skill] {
    [expression]
  }

  /// Converts an optional ``Skill`` expression into the builder's partial
  /// result type, producing an empty array when the value is `nil`.
  public static func buildExpression(_ expression: Skill?) -> [Skill] {
    expression.map { [$0] } ?? []
  }

  /// Supports the first branch of an `if`/`else` statement.
  public static func buildEither(first component: [Skill]) -> [Skill] {
    component
  }

  /// Supports the second branch of an `if`/`else` statement.
  public static func buildEither(second component: [Skill]) -> [Skill] {
    component
  }

  /// Supports `for`-`in` loops by flattening the collected iterations.
  public static func buildArray(_ components: [[Skill]]) -> [Skill] {
    components.flatMap { $0 }
  }
}
