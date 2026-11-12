# Third-Party Notices

TurboCode is Copyright (C) 2026 Luca Travaglini and is licensed under the
GNU General Public License v3.0 only (see `LICENSE`). The components below
are not covered by that grant: each keeps its own license, and all of them are
compatible with distribution under GPL-3.0.

## Included in this repository

| Component | Location | License |
| --- | --- | --- |
| Foundation Models Utilities (Apple Inc. and the Foundation Models project authors) | `Vendor/foundation-models-utilities` | Apache License 2.0 (`Vendor/foundation-models-utilities/LICENSE.txt`) |

The vendored Foundation Models Utilities sources are modified. The changes
are described in `Vendor/foundation-models-utilities/README-TurboCode.md` and
marked with `TurboCode:` comments in the affected files.

## Swift package dependencies

Resolved by Swift Package Manager at build time; versions are pinned in
`TurboCode.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

| Package | License |
| --- | --- |
| apple/containerization | Apache License 2.0 |
| apple/swift-algorithms, swift-argument-parser, swift-asn1, swift-async-algorithms, swift-atomics, swift-certificates, swift-collections, swift-configuration, swift-crypto, swift-distributed-tracing, swift-http-structured-headers, swift-http-types, swift-log, swift-nio, swift-nio-extras, swift-nio-http2, swift-nio-ssl, swift-nio-transport-services, swift-numerics, swift-protobuf, swift-service-context, swift-system | Apache License 2.0 |
| swift-server/async-http-client, swift-service-lifecycle | Apache License 2.0 |
| grpc/grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf | Apache License 2.0 |
| swiftlang/swift-cmark | BSD 2-Clause |
| facebook/zstd | BSD 3-Clause (dual-licensed; used under BSD) |
| migueldeicaza/SwiftTerm | MIT |
| gonzalezreal/swift-markdown-ui | MIT |
| gonzalezreal/NetworkImage | MIT |
