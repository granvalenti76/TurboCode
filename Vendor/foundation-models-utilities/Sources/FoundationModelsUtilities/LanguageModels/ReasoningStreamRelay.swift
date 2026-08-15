//===----------------------------------------------------------------------===//
//
// This source file is part of the Foundation Models open source project.
//
// Copyright © 2024-2027 Apple Inc. and the Foundation Models project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
//===----------------------------------------------------------------------===//

public import Foundation

/// Delivers reasoning deltas without waiting for the Foundation Models
/// transcript snapshots. The relay is intentionally opt-in and token-scoped so
/// it cannot alter normal session behavior or clear a newer request's sink.
public actor ReasoningStreamRelay {
  public static let shared = ReasoningStreamRelay()

  public typealias Sink = @MainActor @Sendable (String) -> Void

  private var sink: Sink?
  private var registrationID: UUID?
  private var accumulatedReasoning = ""

  public init() {}

  @discardableResult
  public func install(_ sink: @escaping Sink) -> UUID {
    let id = UUID()
    registrationID = id
    self.sink = sink
    accumulatedReasoning = ""
    return id
  }

  public func remove(_ id: UUID) {
    guard registrationID == id else { return }
    registrationID = nil
    sink = nil
    accumulatedReasoning = ""
  }

  public func publish(_ reasoning: String) {
    guard let sink else { return }
    accumulatedReasoning += reasoning
    let value = accumulatedReasoning
    // The transport parser must never wait for SwiftUI. Keep the relay
    // observational so a slow main-actor render cannot corrupt or delay the
    // Foundation Models event stream.
    Task { @MainActor in
      sink(value)
    }
  }
}
