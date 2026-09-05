import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, mkdir, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { snapshot, parseStatus, mergeStats } from "../dist/repository.js";

test("NUL paths preserve tabs, newlines, leading spaces and markup", () => {
  const files = parseStatus(" M folder/a\tb\nc\0?? <img>.txt\0");
  mergeStats(files, "3\t2\tfolder/a\tb\nc\0");
  assert.equal(files[0].path, "folder/a\tb\nc");
  assert.equal(files[0].added, 3);
  assert.equal(files[1].path, "<img>.txt");
});
test("binary stats remain explicit", () => {
  const files = parseStatus(" M image.png\0");
  mergeStats(files, "-\t-\timage.png\0");
  assert.equal(files[0].binary, true);
  assert.equal(files[0].added, 0);
});
test("real repository: unborn, staged + unstaged, binary, nested path and unchanged index", async () => {
  const dir = await mkdtemp(join(tmpdir(), "repo-observatory-test-"));
  const git = (...args) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8" });
  git("init", "-q", "-b", "main");
  await writeFile(join(dir, "new.txt"), "hello\n");
  let result = await snapshot(dir);
  assert.equal(result.commit, "");
  assert.equal(result.branch, "main");
  assert.equal(result.files[0].untracked, true);
  git("add", "new.txt");
  result = await snapshot(dir);
  assert.equal(result.files[0].added, 1);
  git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "Fixture");
  assert.equal((await snapshot(dir)).files.length, 0);
  await writeFile(join(dir, "new.txt"), "hello\nsecond\n");
  git("add", "new.txt");
  await writeFile(join(dir, "new.txt"), "hello\nsecond\nthird\n");
  await mkdir(join(dir, "nested"));
  const indexBefore = await readFile(join(dir, ".git/index"));
  result = await snapshot(join(dir, "nested"));
  assert.equal(result.files[0].added, 2);
  assert.equal(result.files[0].staged, true);
  assert.equal(result.files[0].unstaged, true);
  assert.deepEqual(await readFile(join(dir, ".git/index")), indexBefore);
});
test("non-repository gets a truthful empty state; relative paths fail", async () => {
  const dir = await mkdtemp(join(tmpdir(), "repo-observatory-empty-"));
  assert.equal((await snapshot(dir)).state, "no-repository");
  await assert.rejects(snapshot("."), /absolute/);
});
