# The TurboCode Workflow

Start by choosing the workspace that contains the Xcode project, workspace, or Swift package. Describe the result you want and include relevant constraints, expected behavior, or an error message. TurboCode will inspect the smallest useful portion of the project before proposing or applying changes.

For implementation work, a strong request explains the desired user-visible result instead of prescribing every code edit. TurboCode can then read the relevant files, make revision-bound changes, inspect the Xcode schemes, run the most focused available build or test, and report compact source diagnostics rather than a complete compiler log.

Changes appear as persistent widgets in the conversation. Use Review to inspect the real working tree in the Git inspector and Undo when a generated edit should be reverted. Git operations are performed through a structured service rather than opaque shell interpolation.

For best results:

- Keep one conversation focused on one workspace and engineering objective.
- State platform, deployment, compatibility, and UI constraints early.
- Ask TurboCode to verify a change when build or test coverage matters.
- Review generated changes before publishing or merging them.
- Start a new conversation when switching to an unrelated objective.
