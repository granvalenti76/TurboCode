import { copyFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const source = resolve("widget.html");
const destination = resolve("dist/widget.html");

await mkdir(dirname(destination), { recursive: true });
await copyFile(source, destination);
