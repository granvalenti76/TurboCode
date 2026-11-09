import Foundation

/// A server the agent left running in the Cowork VM that the Mac can open,
/// such as a dev server or `python3 -m http.server`.
///
/// It is a view of something live in the guest, not a file: nothing is copied
/// to the Mac and it disappears when the server or the VM stops.
nonisolated struct CoworkLivePreview: Identifiable, Sendable, Hashable {
    let port: Int
    /// The VM's address on the network it shares with the Mac.
    let host: String

    /// Never collides with an artifact ID, which is a relative path and so
    /// cannot start with "/".
    var id: String { "/live/\(port)" }
    var url: URL? { URL(string: "http://\(host):\(port)/") }
    var title: String { "Port \(port)" }
}

/// Finds the servers in the guest that the Mac can reach.
///
/// The model is not asked to announce a server: the guest's own socket table
/// is the source of truth, so a preview appears for whatever is really
/// listening and never for a server that has already exited. Only sockets
/// bound to every interface are offered, because one bound to the guest's
/// loopback address cannot be reached from the Mac.
nonisolated enum CoworkLivePreviewProbe {
    /// Reads `/proc` rather than calling `ss` or `netstat`, which the guest
    /// image is not guaranteed to contain. Prints the listening sockets, a
    /// separator, then the guest's addresses.
    static let script = """
        awk 'FNR > 1 && $4 == "0A" { print $2 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
        echo ---
        hostname -I 2>/dev/null
        """

    /// Ports below this belong to system services (for example a DNS stub),
    /// not to something the agent started for the user to look at.
    static let lowestOfferedPort = 1_024

    static func parse(_ output: String) -> [CoworkLivePreview] {
        let lines = output.components(separatedBy: .newlines)
        guard let separator = lines.firstIndex(of: "---") else { return [] }
        // The first IPv4 address is the interface the Mac shares with the VM;
        // without one the guest has no network and nothing is reachable.
        guard let host = lines[(separator + 1)...]
            .flatMap({ $0.split(whereSeparator: \.isWhitespace) })
            .map(String.init)
            .first(where: { $0.split(separator: ".").count == 4 }) else { return [] }

        var ports = Set<Int>()
        for line in lines[..<separator] {
            // "<hex address>:<hex port>"; the address is 8 hex digits for
            // IPv4 and 32 for IPv6, and all zeros means every interface.
            guard let colon = line.lastIndex(of: ":") else { continue }
            let address = line[..<colon]
            guard !address.isEmpty, address.allSatisfy({ $0 == "0" }),
                  let port = Int(line[line.index(after: colon)...], radix: 16),
                  port >= lowestOfferedPort else { continue }
            ports.insert(port)
        }
        return ports.sorted().map { CoworkLivePreview(port: $0, host: host) }
    }
}

/// Decides what the inspector shows after a reload when both running servers
/// and files exist.
nonisolated enum CoworkLivePreviewSelection {
    /// A server that just appeared wins, and so does a running server when
    /// nothing is selected yet: it is the current state of the work. A
    /// selected server stays while it runs. Otherwise the file rule applies,
    /// passed in as `artifact`. `previousLive` is `nil` on a session's first
    /// load, when nothing counts as new.
    static func selection(
        current: String?,
        previousLive: [CoworkLivePreview]?,
        updatedLive: [CoworkLivePreview],
        artifact: CoworkArtifact?
    ) -> String? {
        if let previousLive {
            let known = Set(previousLive.map(\.id))
            if let started = updatedLive.first(where: { !known.contains($0.id) }) { return started.id }
        } else if current == nil, let running = updatedLive.first {
            return running.id
        }
        if let current, updatedLive.contains(where: { $0.id == current }) { return current }
        return artifact?.id ?? updatedLive.first?.id
    }
}
