# Foundation Models Utilities compatibility copy

This directory contains Apple’s `foundation-models-utilities` sources from
commit `376ca60e61985369d5067bd3c575bdb6a13f0e1b` (`1.0.0-beta3`). The sources
remain under the Apache License 2.0 included in `LICENSE.txt`.

TurboCode temporarily uses this local package because Xcode 27 beta 5 removed
`Transcript.Segment.custom`, while the upstream package still switches over
that case and therefore does not compile. The compatibility change removes
only that obsolete case from `ChatCompletionsLanguageModel`; the
`@unknown default` branch continues to reject unsupported future segments.

Remove this directory and restore the remote Xcode package reference after
Apple publishes an upstream release compatible with Xcode 27 beta 5 or later.
