# ``FoundationModelsUtilities``

Utilities and support for common patterns working with the Foundation Models API

## Overview

`FoundationModelsUtilities` extends Foundation Models with additional building blocks for common patterns:

- **Chat completions integration.** ``ChatCompletionsLanguageModel`` lets a `LanguageModelSession` talk to any server that implements the OpenAI Chat Completions REST API — useful for local inference servers, hosted providers, and the broader ecosystem of open-source tooling built around that protocol.

- **History management.** Profile modifiers like ``FoundationModels/LanguageModelSession/DynamicProfile/droppingCompletedToolCalls()``, ``FoundationModels/LanguageModelSession/DynamicProfile/rollingWindow(entries:)``, and ``FoundationModels/LanguageModelSession/DynamicProfile/summarizeHistory(entryThreshold:model:instructions:summaryPostamble:)`` keep a session's transcript from outgrowing the model's context window. They compose, so you can mix strategies to suit your app's conversation pattern.

- **Skills.** ``Skills`` and ``Skill`` teach a session about specialized tasks just-in-time. The model activates a skill by issuing a tool call, and the corresponding prompt or instructions content is added to the transcript only when needed — keeping the upfront context small and protecting the key-value cache.

## Topics

### Language Models

- ``ChatCompletionsLanguageModel``

### Skills

- ``Skill``
- ``Skills``
- ``SkillActivations``
- ``SkillsBuilder``

### Context Management

- ``FoundationModels/LanguageModelSession/DynamicProfile/summarizeHistory(entryThreshold:model:instructions:summaryPostamble:)``
- ``FoundationModels/LanguageModelSession/DynamicProfile/rollingWindow(entries:)``
- ``FoundationModels/LanguageModelSession/DynamicProfile/rollingWindow(size:)``
- ``RollingWindowSize``
- ``FoundationModels/LanguageModelSession/DynamicProfile/droppingCompletedToolCalls()``
