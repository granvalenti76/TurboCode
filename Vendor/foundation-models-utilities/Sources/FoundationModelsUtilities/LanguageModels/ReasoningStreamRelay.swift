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
  /// Request-local source of truth used when an interrupted stream settles
  /// before the asynchronous presentation drain reaches the main actor.
  private var accumulatedText = ""

  // TurboCode: tool-call side channel. The registration is independent from
  // the reasoning sink so a backend can observe tool calls without opting in
  // to relay-driven reasoning, and removing one never clears the other.
  fileprivate var toolCallSink: ToolCallSink?
  fileprivate var toolCallRegistrationID: UUID?
  /// Coalesced updates waiting for the main actor, in first-seen order.
  fileprivate var pendingToolCallUpdates: [ToolCallUpdate] = []
  fileprivate var toolCallDeliveryScheduled = false
  /// Calls seen on the provider stream that is currently open. They are
  /// marked complete together when that stream ends.
  fileprivate var openToolCallStreamID: UUID?
  fileprivate var openToolCalls: [Int: (id: String, name: String)] = [:]

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
    accumulatedText.removeAll(keepingCapacity: true)
    return id
  }

  /// Returns all reasoning published for the installed request, including
  /// deltas that are still waiting for presentation delivery.
  public func textSnapshot() -> String {
    accumulatedText
  }

  public func remove(_ id: UUID) {
    guard registrationID == id else { return }
    registrationID = nil
    sink = nil
    nextSequence = 0
    pendingDelta.removeAll(keepingCapacity: true)
    pendingSequence = 0
    deliveryScheduled = false
    accumulatedText.removeAll(keepingCapacity: true)
  }

  public func publish(_ reasoning: String) {
    guard !reasoning.isEmpty,
          sink != nil,
          registrationID != nil else { return }
    nextSequence &+= 1
    accumulatedText += reasoning
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

// MARK: - TurboCode: streamed tool calls

extension ReasoningStreamRelay {

  /// One coalesced step of a tool call that the model is still writing.
  ///
  /// Foundation Models exposes a tool call only once its arguments are
  /// complete. This side channel forwards the argument fragments as they
  /// arrive so a looping or runaway call is visible while it is generated.
  public struct ToolCallUpdate: Sendable, Equatable {
    public let registrationID: UUID
    /// Identifies one provider response stream, i.e. one round of the tool
    /// loop. Tool-call indexes restart at zero on every stream.
    public let streamID: UUID
    public let index: Int
    public let id: String
    public let name: String
    /// Argument text added since the previous update for this call.
    public let argumentsDelta: String
    /// Number of transport fragments merged into `argumentsDelta`; providers
    /// emit roughly one fragment per token.
    public let fragmentCount: Int
    /// True once the provider stream that carried the call has ended.
    public let isComplete: Bool

    public init(
      registrationID: UUID,
      streamID: UUID,
      index: Int,
      id: String,
      name: String,
      argumentsDelta: String,
      fragmentCount: Int,
      isComplete: Bool
    ) {
      self.registrationID = registrationID
      self.streamID = streamID
      self.index = index
      self.id = id
      self.name = name
      self.argumentsDelta = argumentsDelta
      self.fragmentCount = fragmentCount
      self.isComplete = isComplete
    }
  }

  /// Receives every update still pending when the main actor becomes
  /// available, in transport order.
  public typealias ToolCallSink = @MainActor @Sendable ([ToolCallUpdate]) async -> Void

  @discardableResult
  public func installToolCallSink(_ sink: @escaping ToolCallSink) -> UUID {
    let id = UUID()
    toolCallRegistrationID = id
    toolCallSink = sink
    resetToolCallState()
    return id
  }

  public func removeToolCallSink(_ id: UUID) {
    guard toolCallRegistrationID == id else { return }
    toolCallRegistrationID = nil
    toolCallSink = nil
    resetToolCallState()
  }

  /// Publishes one argument fragment. `id` and `name` are the values latched
  /// for this index so far; a fragment may be empty when a delta only
  /// announced the call.
  public func publishToolCall(
    streamID: UUID,
    index: Int,
    id: String,
    name: String,
    argumentsDelta: String
  ) {
    guard toolCallSink != nil, let registrationID = toolCallRegistrationID else { return }
    if openToolCallStreamID != streamID {
      openToolCallStreamID = streamID
      openToolCalls.removeAll(keepingCapacity: true)
    }
    openToolCalls[index] = (id: id, name: name)
    enqueueToolCallUpdate(
      ToolCallUpdate(
        registrationID: registrationID,
        streamID: streamID,
        index: index,
        id: id,
        name: name,
        argumentsDelta: argumentsDelta,
        fragmentCount: argumentsDelta.isEmpty ? 0 : 1,
        isComplete: false
      )
    )
  }

  /// Marks every call of a provider stream as completely written. A stream
  /// that fails or is cancelled never reaches this point; the consumer closes
  /// such calls when its own request ends.
  public func finishToolCalls(streamID: UUID) {
    guard toolCallSink != nil,
          let registrationID = toolCallRegistrationID,
          openToolCallStreamID == streamID else { return }
    for index in openToolCalls.keys.sorted() {
      guard let call = openToolCalls[index] else { continue }
      enqueueToolCallUpdate(
        ToolCallUpdate(
          registrationID: registrationID,
          streamID: streamID,
          index: index,
          id: call.id,
          name: call.name,
          argumentsDelta: "",
          fragmentCount: 0,
          isComplete: true
        )
      )
    }
    openToolCallStreamID = nil
    openToolCalls.removeAll(keepingCapacity: true)
  }

  private func resetToolCallState() {
    pendingToolCallUpdates.removeAll(keepingCapacity: true)
    toolCallDeliveryScheduled = false
    openToolCallStreamID = nil
    openToolCalls.removeAll(keepingCapacity: true)
  }

  private func enqueueToolCallUpdate(_ update: ToolCallUpdate) {
    // Merge into the pending update of the same call so a slow main actor
    // receives one growing delta instead of one hop per token. A completed
    // update is terminal and is never merged into.
    if let pendingIndex = pendingToolCallUpdates.lastIndex(where: {
      $0.streamID == update.streamID && $0.index == update.index
    }), !pendingToolCallUpdates[pendingIndex].isComplete {
      let pending = pendingToolCallUpdates[pendingIndex]
      pendingToolCallUpdates[pendingIndex] = ToolCallUpdate(
        registrationID: update.registrationID,
        streamID: update.streamID,
        index: update.index,
        id: update.id,
        name: update.name,
        argumentsDelta: pending.argumentsDelta + update.argumentsDelta,
        fragmentCount: pending.fragmentCount + update.fragmentCount,
        isComplete: update.isComplete
      )
    } else {
      pendingToolCallUpdates.append(update)
    }

    guard !toolCallDeliveryScheduled else { return }
    toolCallDeliveryScheduled = true
    // Same rule as reasoning: the transport parser never waits for SwiftUI.
    Task { @MainActor [weak self] in
      await self?.deliverPendingToolCallUpdates()
    }
  }

  private func nextToolCallDelivery() -> (sink: ToolCallSink, updates: [ToolCallUpdate])? {
    guard !pendingToolCallUpdates.isEmpty, let toolCallSink else {
      pendingToolCallUpdates.removeAll(keepingCapacity: true)
      toolCallDeliveryScheduled = false
      return nil
    }
    let updates = pendingToolCallUpdates
    pendingToolCallUpdates.removeAll(keepingCapacity: true)
    return (toolCallSink, updates)
  }

  private func deliverPendingToolCallUpdates() async {
    while !Task.isCancelled {
      guard let delivery = nextToolCallDelivery() else { return }
      await delivery.sink(delivery.updates)
      await Task.yield()
    }
    pendingToolCallUpdates.removeAll(keepingCapacity: true)
    toolCallDeliveryScheduled = false
  }
}
