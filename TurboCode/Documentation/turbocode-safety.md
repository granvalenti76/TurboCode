# Safety, Review, and Control

TurboCode treats deterministic services—not model confidence—as the source of operational safety.

All project tools are bounded to the active workspace. Standardized and symlink-resolved paths prevent access outside that boundary. Source edits are tied to a fresh content revision, preventing a model from overwriting a file that changed after it was inspected.

Normal reversible work runs without unnecessary interruptions. Operations that can discard work, rewrite history, delete files, or publish consequential remote changes require explicit approval according to the configured policy.

Generated edits appear in the conversation with additions, deletions, status, Review, and Undo. Git state is read from the real working tree so the visual inspector remains an authoritative view of project changes.

Credentials are stored in the macOS Keychain. Configuration files contain model endpoints and credential references, never secret values. Diagnostic records avoid prompts, generated content, file contents, and paths.
