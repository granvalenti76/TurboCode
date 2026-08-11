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

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  // Keep the upstream module and product names unchanged so TurboCode can
  // remove this temporary local override without touching application code.
  name: "foundation-models-utilities",
  platforms: [
    .macOS("27.0"),
    .iOS("27.0"),
    .visionOS("27.0"),
    .watchOS("27.0")
  ],
  products: [
    .library(
      name: "FoundationModelsUtilities",
      targets: ["FoundationModelsUtilities"]
    )
  ],
  targets: [
    .target(
      name: "FoundationModelsUtilities",
      dependencies: [],
      swiftSettings: [
        .enableExperimentalFeature("InternalImportsByDefault"),
        .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("MemberImportVisibility")
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
