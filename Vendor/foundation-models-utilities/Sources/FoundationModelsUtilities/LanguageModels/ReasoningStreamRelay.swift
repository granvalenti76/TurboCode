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
/// transcript snapshots. A relay belongs to one model session; each
/// registration belongs to one request so concurrent sessions cannot share a
/// process-wide sink or clear a newer request's state.
public actor ReasoningStreamRelay {

  public struct Event: Sendable, Equatable {
    public let requestID: UUID
    public let sequence: UInt64
    public let delta: String

    public init(requestID: UUID, sequence: UInt64, delta: String) {
      self.requestID = requestID
      self.sequence = sequence
      self.delta = delta
    }
  }

  /// Async delivery preserves backpressure when the consumer is an actor-backed
  /// runtime. A later reasoning delta cannot overtake an earlier UI projection.
  public typealias Sink = @MainActor @Sendable (Event) async -> Void

  private var sink: Sink?
  private var registrationID: UUID?
  private var nextSequence: UInt64 = 0
  /// Deltas are accumulated until the main actor is ready to receive them.
  /// This avoids creating one main-actor task for every server token while
  /// preserving the transport order inside the coalesced event.
  private var pendingDelta = ""
  private var pendingSequence: UInt64 = 0
  private var deliveryScheduled = false

  public init() {}

  @discardableResult
  public func install(_ sink: @escaping Sink) -> UUID {
    let id = UUID()
    registrationID = id
    self.sink = sink
    nextSequence = 0
    pendingDelta.removeAll(keepingCapacity: true)
    pendingSequence = 0
    deliveryScheduled = false
    return id
  }

  public func remove(_ id: UUID) {
    guard registrationID == id else { return }
    registrationID = nil
    sink = nil
    nextSequence = 0
    pendingDelta.removeAll(keepingCapacity: true)
    pendingSequence = 0
    deliveryScheduled = false
  }

  public func publish(_ reasoning: String) {
    guard !reasoning.isEmpty,
          sink != nil,
          registrationID != nil else { return }
    nextSequence &+= 1
    pendingDelta += reasoning
    pendingSequence = nextSequence

    guard !deliveryScheduled else { return }
    deliveryScheduled = true

    // The transport parser must never wait for SwiftUI. A single drain task
    // observes all deltas currently available and yields between deliveries,
    // so a slow render cannot corrupt or block the Foundation Models stream.
    Task { @MainActor [weak self] in
      await self?.deliverPendingEvents()
    }
  }

  private struct PendingDelivery: Sendable {
    let sink: Sink
    let event: Event
  }

  private func nextPendingDelivery() -> PendingDelivery? {
    guard !pendingDelta.isEmpty,
          let sink,
          let requestID = registrationID else {
      pendingDelta.removeAll(keepingCapacity: true)
      pendingSequence = 0
      deliveryScheduled = false
      return nil
    }

    let event = Event(
      requestID: requestID,
      sequence: pendingSequence,
      delta: pendingDelta
    )
    pendingDelta.removeAll(keepingCapacity: true)
    pendingSequence = 0
    return PendingDelivery(sink: sink, event: event)
  }

  private func deliverPendingEvents() async {
    while !Task.isCancelled {
      guard let delivery = nextPendingDelivery() else { return }
      await delivery.sink(delivery.event)
      await Task.yield()
    }

    pendingDelta.removeAll(keepingCapacity: true)
    pendingSequence = 0
    deliveryScheduled = false
  }
}
