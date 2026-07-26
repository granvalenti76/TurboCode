# AGENTS.md

# TurboCode Development Guide

## Mission

TurboCode is a native Swift / SwiftUI macOS application.

The primary goal is to make the smallest correct change that satisfies the requested feature or bug fix.

Avoid architectural rewrites unless explicitly requested.

---

# General workflow

Always follow this workflow.

1. Understand the request.
2. Identify the minimum set of files involved.
3. Read only those files.
4. Follow only direct dependencies.
5. Explain the implementation plan.
6. Wait for approval if the requested change is significant.
7. Implement.
8. Run targeted verification.
9. Summarize changes.

Never skip directly to implementation.

---

# Repository exploration policy

Repository-wide exploration is expensive.

DO NOT scan the whole repository unless explicitly requested.

Prefer targeted exploration.

Good:

- "Read LoginView.swift"
- "Inspect AuthService.swift"
- "Follow references from ConversationRepository"

Bad:

- "Analyze the whole project"
- "Understand the entire architecture"

---

# Scope policy

Stay inside the requested scope.

Do not:

- clean unrelated code
- rename symbols outside the feature
- reformat unrelated files
- perform opportunistic refactors

Only touch files required by the task.

---

# Reading policy

Read files lazily.

Only open another file when it is necessary to understand the current one.

Avoid recursive repository exploration.

---

# Architecture

Typical layering:

Views
↓

ViewModels

↓

Services

↓

Models

Avoid bypassing the architecture.

Business logic belongs in Services.

Views should remain lightweight.

---

# Swift guidelines

Prefer:

- Swift Concurrency
- async/await
- actors when shared mutable state exists
- Sendable where appropriate

Avoid:

- unnecessary DispatchQueue usage
- callback pyramids
- force unwraps
- force casts

---

# SwiftUI guidelines

Views should:

- remain declarative
- avoid business logic
- avoid networking
- avoid persistence

Prefer moving logic into ViewModels or Services.

---

# Refactoring

Only refactor when:

- required by the feature
- fixing an actual design issue
- explicitly requested

Never refactor "because it looks nicer."

---

# Testing

Run only relevant tests first.

Avoid running the full test suite unless requested.

If no tests exist:

Explain what should be tested manually.

---

# Output style

Before implementation:

Return:

- files involved
- implementation plan
- assumptions
- risks

After implementation:

Return:

- modified files
- summary
- possible regressions
- recommended tests

Keep explanations concise.

---

# Performance

Minimize token usage.

Avoid repeating previous analyses.

Reuse information already discovered.

Do not restate repository structure repeatedly.

---

# If uncertain

Ask.

Do not invent architecture.

Do not guess APIs.

Do not create new abstractions without justification.
