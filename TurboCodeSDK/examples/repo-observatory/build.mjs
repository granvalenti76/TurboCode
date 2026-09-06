import { copyFile } from "node:fs/promises";
await copyFile(new URL("./widget.html", import.meta.url), new URL("./dist/widget.html", import.meta.url));
