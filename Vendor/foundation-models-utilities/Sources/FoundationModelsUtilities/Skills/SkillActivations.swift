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
public import Observation
import Synchronization

/// A collection of active skill identifiers that tracks which skills
/// have been activated during a language model session.
///
/// Create an instance and pass it to ``Skills`` to provide the backing
/// storage for skill activation state. Because `SkillActivations`
/// conforms to `Observable`, you can use it to drive UI updates or
/// other reactions when the model activates or deactivates skills.
///
public final class SkillActivations: Sendable, Observable {
  private let _registrar = ObservationRegistrar()
  private let _names = Mutex<[String]>([])

  public init() {}

  public func activate(_ name: String) {
    _registrar.withMutation(of: self, keyPath: \.activeSkillNames) {
      _names.withLock { names in
        guard !names.contains(name) else { return }
        names.append(name)
      }
    }
  }

  public func deactivate(_ name: String) {
    _registrar.withMutation(of: self, keyPath: \.activeSkillNames) {
      _names.withLock { names in
        names.removeAll(where: { $0 == name })
      }
    }
  }

  /// Returns whether the skill with the given name is currently active.
  public func isActive(_ name: String) -> Bool {
    activeSkillNames.contains(name)
  }

  /// The names of all currently active skills.
  public var activeSkillNames: [String] {
    _registrar.access(self, keyPath: \.activeSkillNames)
    return _names.withLock { $0 }
  }
}
