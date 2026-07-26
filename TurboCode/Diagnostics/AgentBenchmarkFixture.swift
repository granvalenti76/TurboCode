import Foundation

#if DEBUG
/// Domains exercised by the live agent benchmark. Keeping both fixtures behind
/// one contract makes Llama/PCC comparisons use identical success semantics.
nonisolated enum AgentBenchmarkKind: String, Sendable {
    case swiftPackage = "swift-package"
    case xcodeProject = "xcode-project"

    var workspaceKind: String { rawValue }

    var profileInstructions: String {
        switch self {
        case .swiftPackage:
            "You are running TurboCode's deterministic Swift package benchmark."
        case .xcodeProject:
            "You are running TurboCode's deterministic Xcode project benchmark."
        }
    }

    var prompt: String {
        switch self {
        case .swiftPackage:
            """
            This workspace is a Swift package. In Sample.md, replace the Placeholder
            line with exactly two prose paragraphs.
            The first paragraph must be "TurboCode edits quickly." and the second must be
            "Paragraph breaks stay intact." Separate them with one blank line. Use the
            editing tool, read the file after the edit, and run swift build with bash
            before finishing.
            """
        case .xcodeProject:
            """
            This workspace contains an Xcode project named Benchmark.xcodeproj. First
            inspect it with xcode_project. In Sources/Benchmark/main.swift, replace only
            line 1 with exactly: print("TurboCode Xcode loop verified.")
            Use read_file and edit_file, read the file after editing, then build the
            discovered Benchmark scheme with xcode_project before finishing.
            """
        }
    }

    var expectedFilePath: String {
        switch self {
        case .swiftPackage: "Sample.md"
        case .xcodeProject: "Sources/Benchmark/main.swift"
        }
    }

    var expectedContent: String {
        switch self {
        case .swiftPackage:
            """
            # Notes

            TurboCode edits quickly.

            Paragraph breaks stay intact.
            """
        case .xcodeProject:
            "print(\"TurboCode Xcode loop verified.\")"
        }
    }

    var requiredToolNames: Set<String> {
        switch self {
        case .swiftPackage: ["read_file", "edit_file", "bash"]
        case .xcodeProject: ["read_file", "edit_file", "xcode_project"]
        }
    }
}

/// Creates disposable, real build containers rather than mocked tool output.
/// The Xcode fixture uses a shared legacy scheme whose build command delegates
/// to SwiftPM, allowing Xcode discovery and xcresult handling to remain genuine.
nonisolated enum AgentBenchmarkFixture {
    static func make(_ kind: AgentBenchmarkKind) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCodeBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        switch kind {
        case .swiftPackage:
            try writeSwiftPackageFixture(to: directory, includesXcodeProject: false)
        case .xcodeProject:
            try writeSwiftPackageFixture(to: directory, includesXcodeProject: true)
        }
        try initializeGit(in: directory)
        return directory
    }

    private static func writeSwiftPackageFixture(
        to directory: URL,
        includesXcodeProject: Bool
    ) throws {
        if includesXcodeProject {
            let sourceDirectory = directory
                .appendingPathComponent("Sources/Benchmark", isDirectory: true)
            try FileManager.default.createDirectory(
                at: sourceDirectory,
                withIntermediateDirectories: true
            )
            try "print(\"Placeholder\")".write(
                to: sourceDirectory.appendingPathComponent("main.swift"),
                atomically: true,
                encoding: .utf8
            )
            try xcodeProject.write(
                to: projectFile(in: directory),
                atomically: true,
                encoding: .utf8
            )
            try sharedScheme.write(
                to: schemeFile(in: directory),
                atomically: true,
                encoding: .utf8
            )
        } else {
            try """
            # Notes

            Placeholder
            """.write(
                to: directory.appendingPathComponent("Sample.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        // A real manifest gives both domains a compiler-backed completion gate.
        let targetClause = includesXcodeProject
            ? """
              products: [.executable(name: "Benchmark", targets: ["Benchmark"])],
              targets: [.executableTarget(name: "Benchmark")]
            """
            : ""
        try """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "BenchmarkFixture"\(targetClause.isEmpty ? "" : ",\n\(targetClause)")
        )
        """.write(
            to: directory.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func projectFile(in directory: URL) throws -> URL {
        let projectDirectory = directory
            .appendingPathComponent("Benchmark.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        return projectDirectory.appendingPathComponent("project.pbxproj")
    }

    private static func schemeFile(in directory: URL) throws -> URL {
        let schemeDirectory = directory
            .appendingPathComponent(
                "Benchmark.xcodeproj/xcshareddata/xcschemes",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: schemeDirectory,
            withIntermediateDirectories: true
        )
        return schemeDirectory.appendingPathComponent("Benchmark.xcscheme")
    }

    private static func initializeGit(in directory: URL) throws {
        try runGit(["init", "--quiet"], in: directory)
        try runGit(["add", "."], in: directory)
        try runGit(
            [
                "-c", "user.name=TurboCode Benchmark",
                "-c", "user.email=benchmark@localhost",
                "commit", "--quiet", "-m", "Initial fixture"
            ],
            in: directory
        )
    }

    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not prepare benchmark Git fixture: "
                        + String(decoding: data, as: UTF8.self)
                ]
            )
        }
    }

    private static let xcodeProject = """
    // !$*UTF8*$!
    {
        archiveVersion = 1;
        classes = {};
        objectVersion = 77;
        objects = {
            000000000000000000000001 = {
                isa = PBXProject;
                attributes = {
                    BuildIndependentTargetsInParallel = 1;
                    LastSwiftUpdateCheck = 2700;
                    LastUpgradeCheck = 2700;
                };
                buildConfigurationList = 000000000000000000000004;
                compatibilityVersion = "Xcode 16.0";
                developmentRegion = en;
                hasScannedForEncodings = 0;
                knownRegions = (en, Base);
                mainGroup = 000000000000000000000002;
                productRefGroup = 000000000000000000000002;
                projectDirPath = "";
                projectRoot = "";
                targets = (000000000000000000000003);
            };
            000000000000000000000002 = {
                isa = PBXGroup;
                children = ();
                sourceTree = "<group>";
            };
            000000000000000000000003 = {
                isa = PBXLegacyTarget;
                buildArgumentsString = "build";
                buildConfigurationList = 000000000000000000000005;
                buildPhases = ();
                buildToolPath = /usr/bin/swift;
                buildWorkingDirectory = "$(PROJECT_DIR)";
                dependencies = ();
                name = Benchmark;
                passBuildSettingsInEnvironment = 1;
                productName = Benchmark;
            };
            000000000000000000000004 = {
                isa = XCConfigurationList;
                buildConfigurations = (
                    000000000000000000000006,
                    000000000000000000000007,
                );
                defaultConfigurationIsVisible = 0;
                defaultConfigurationName = Release;
            };
            000000000000000000000005 = {
                isa = XCConfigurationList;
                buildConfigurations = (
                    000000000000000000000008,
                    000000000000000000000009,
                );
                defaultConfigurationIsVisible = 0;
                defaultConfigurationName = Release;
            };
            000000000000000000000006 = {
                isa = XCBuildConfiguration;
                buildSettings = {};
                name = Debug;
            };
            000000000000000000000007 = {
                isa = XCBuildConfiguration;
                buildSettings = {};
                name = Release;
            };
            000000000000000000000008 = {
                isa = XCBuildConfiguration;
                buildSettings = {};
                name = Debug;
            };
            000000000000000000000009 = {
                isa = XCBuildConfiguration;
                buildSettings = {};
                name = Release;
            };
        };
        rootObject = 000000000000000000000001;
    }
    """

    private static let sharedScheme = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion="2700" version="1.7">
       <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
          <BuildActionEntries>
             <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
                <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="000000000000000000000003" BuildableName="Benchmark" BlueprintName="Benchmark" ReferencedContainer="container:Benchmark.xcodeproj"/>
             </BuildActionEntry>
          </BuildActionEntries>
       </BuildAction>
    </Scheme>
    """
}
#endif
