import Foundation

/// Command-line entry point used by Xcode's Add an ACP Agent flow.
///
/// stdout is reserved for newline-delimited JSON-RPC. Diagnostics must use
/// stderr or the host process will corrupt the ACP stream.
@main
struct TurboCodeACPMain {
    static func main() async {
        let runtime = await MainActor.run {
            ACPApplicationRuntimeAdapter.makeDefault()
        }
        let driver = ACPRuntimeDriver(runtime: runtime)
        let server = ACPAgentServer(
            driver: driver,
            agentName: "TurboCode",
            agentVersion: "0.1.0",
            writeLine: { data in
                FileHandle.standardOutput.write(data)
            }
        )
        await ACPStdioServer(server: server).run()
    }
}
