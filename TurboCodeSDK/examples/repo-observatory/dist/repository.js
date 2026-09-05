import { execFile } from "node:child_process";
import { stat } from "node:fs/promises";
import { basename, isAbsolute } from "node:path";
/** NUL framing preserves spaces, tabs and newlines in Git paths. Renames are
 * deliberately represented as delete/add by all commands for consistent keys. */
export function parseStatus(raw) {
    return raw.split("\0").filter(Boolean).map(record => {
        const code = record.slice(0, 2);
        return {
            path: record.slice(3), status: code, staged: code[0] !== " " && code !== "??",
            unstaged: code[1] !== " ", added: 0, removed: 0, binary: false, untracked: code === "??",
        };
    });
}
export function mergeStats(files, raw) {
    const byPath = new Map(files.map(file => [file.path, file]));
    for (const record of raw.split("\0").filter(Boolean)) {
        const first = record.indexOf("\t"), second = record.indexOf("\t", first + 1);
        const file = byPath.get(record.slice(second + 1));
        if (!file || first < 0 || second < 0)
            continue;
        const plus = record.slice(0, first), minus = record.slice(first + 1, second);
        file.binary ||= plus === "-" || minus === "-";
        file.added += Number(plus) || 0;
        file.removed += Number(minus) || 0;
    }
}
export async function snapshot(directory, signal) {
    if (!isAbsolute(directory))
        throw new Error("Workspace path must be absolute.");
    if (!(await stat(directory)).isDirectory())
        throw new Error("Workspace path must be a directory.");
    // execFile passes arguments directly: no shell interpolation, external diff,
    // textconv, optional index refresh or filesystem writes are requested.
    const git = (args) => new Promise((resolve, reject) => {
        execFile("git", ["--no-optional-locks", "-C", directory, ...args], {
            encoding: "utf8", timeout: 10_000, maxBuffer: 4 * 1024 * 1024, signal,
            env: { ...process.env, GIT_TERMINAL_PROMPT: "0", LC_ALL: "C" },
        }, (error, stdout, stderr) => {
            if (error)
                reject(new Error(stderr.trim() || error.message));
            else
                resolve(stdout);
        });
    });
    const capturedAt = new Date().toISOString();
    let root;
    try {
        root = (await git(["rev-parse", "--show-toplevel"])).trim();
    }
    catch (error) {
        if (!(error instanceof Error) || !error.message.includes("not a git repository"))
            throw error;
        return { state: "no-repository", name: basename(directory), root: directory, branch: "—", commit: "", capturedAt, files: [] };
    }
    // Run subsequent commands at the root so paths and statistics agree even
    // when the user starts in a nested workspace folder.
    directory = root;
    const before = await git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"]);
    const files = parseStatus(before);
    const stats = ["--numstat", "-z", "--no-renames", "--no-ext-diff", "--no-textconv"];
    mergeStats(files, await git(["diff", ...stats]));
    mergeStats(files, await git(["diff", "--cached", ...stats]));
    let branch = (await git(["rev-parse", "--abbrev-ref", "HEAD"]).catch(() => "")).trim();
    if (!branch)
        branch = (await git(["symbolic-ref", "--short", "HEAD"])).trim();
    if (branch === "HEAD")
        branch = "detached · " + (await git(["rev-parse", "--short", "HEAD"])).trim();
    const commit = (await git(["log", "-1", "--format=%h · %s"]).catch(() => "")).trim();
    const after = await git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"]);
    if (before !== after)
        throw new Error("Repository changed during inspection. Run Repo Observatory again.");
    return { state: "repository", name: basename(root), root, branch, commit, capturedAt, files };
}
