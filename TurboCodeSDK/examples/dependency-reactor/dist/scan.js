import { readdir, readFile, realpath, stat } from "node:fs/promises";
import { isAbsolute, join, relative, basename } from "node:path";
/** Mask comments and string literals while retaining newlines. Imports are
 * lexical references, including conditional imports, never compiler resolution. */
export function imports(source) {
    // Swift block comments can nest and raw strings can contain quotes. Walk
    // delimiters instead of using a regex that could expose a fictional import.
    let masked = "", i = 0;
    const hide = (end) => { masked += source.slice(i, end).replace(/[^\n]/g, " "); i = end; };
    while (i < source.length) {
        if (source.startsWith("//", i)) {
            const end = source.indexOf("\n", i);
            hide(end < 0 ? source.length : end);
            continue;
        }
        if (source.startsWith("/*", i)) {
            let end = i + 2, depth = 1;
            while (end < source.length && depth) {
                if (source.startsWith("/*", end)) {
                    depth++;
                    end += 2;
                }
                else if (source.startsWith("*/", end)) {
                    depth--;
                    end += 2;
                }
                else
                    end++;
            }
            hide(end);
            continue;
        }
        const opening = source.slice(i).match(/^(#*)("""|")/);
        if (opening) {
            const close = opening[2] + opening[1];
            let end = i + opening[0].length;
            while (end < source.length) {
                if (source.startsWith("\\" + opening[1], end)) {
                    end += 2 + opening[1].length;
                    continue;
                }
                if (source.startsWith(close, end)) {
                    end += close.length;
                    break;
                }
                end++;
            }
            hide(Math.min(end, source.length));
            continue;
        }
        masked += source[i++];
    }
    return masked.split("\n").flatMap((line, index) => {
        const match = line.match(/^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|package|fileprivate)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_]\w*)/);
        return match ? [{ name: match[1], line: index + 1 }] : [];
    });
}
export async function scan(path, signal) {
    if (!isAbsolute(path))
        throw new Error("Use an absolute workspace path.");
    const root = await realpath(path);
    if (!(await stat(root)).isDirectory())
        throw new Error("Workspace must be a directory.");
    const groups = new Map(), modules = new Map(), edges = new Map();
    const notes = [];
    let fileCount = 0, visited = 0, bytes = 0, skipped = 0, limited = false;
    const excluded = new Set([".git", ".build", "node_modules", "dist", "DerivedData", "Vendor", "Pods", "Carthage"]);
    async function walk(directory, depth) {
        signal?.throwIfAborted();
        if (depth > 12) {
            limited = true;
            return;
        }
        const entries = await readdir(directory, { withFileTypes: true });
        for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
            signal?.throwIfAborted();
            if (++visited > 20000 || fileCount >= 2000 || bytes > 16 * 1024 * 1024) {
                limited = true;
                return;
            }
            if (entry.isSymbolicLink() || entry.name.startsWith(".") || excluded.has(entry.name))
                continue;
            const full = join(directory, entry.name);
            if (entry.isDirectory()) {
                await walk(full, depth + 1);
                continue;
            }
            if (!entry.isFile() || !entry.name.endsWith(".swift"))
                continue;
            const info = await stat(full);
            if (info.size > 512 * 1024) {
                skipped++;
                continue;
            }
            let source;
            try {
                source = await readFile(full, "utf8");
            }
            catch {
                skipped++;
                continue;
            }
            bytes += info.size;
            fileCount++;
            const file = relative(root, full), parts = file.split("/");
            // Keep two directory levels so app source areas remain navigable. These
            // are explicitly labelled folder groups, not inferred Swift targets.
            const group = parts.length > 1 ? parts.slice(0, Math.min(2, parts.length - 1)).join("/") : "Root files";
            const id = "group:" + group;
            if (!groups.has(id))
                groups.set(id, { id, name: group, kind: "group", files: 0 });
            groups.get(id).files++;
            for (const item of imports(source)) {
                const target = "module:" + item.name;
                if (!modules.has(target))
                    modules.set(target, { id: target, name: item.name, kind: "module", files: 0 });
                const key = id + "→" + target;
                if (!edges.has(key))
                    edges.set(key, { source: id, target, count: 0, evidence: [] });
                const edge = edges.get(key);
                edge.count++;
                if (edge.evidence.length < 30)
                    edge.evidence.push({ path: file, line: item.line });
            }
        }
    }
    await walk(root, 0);
    if (limited)
        notes.push("Partial scan: file, byte, entry or depth limit reached.");
    if (skipped)
        notes.push(skipped + " unreadable or oversized files skipped.");
    notes.push("Swift import references only; conditional imports are included. Vendor, build, hidden and symlinked paths are excluded.");
    return { name: basename(root), root, capturedAt: new Date().toISOString(), fileCount,
        nodes: [...groups.values(), ...modules.values()], edges: [...edges.values()], notes };
}
