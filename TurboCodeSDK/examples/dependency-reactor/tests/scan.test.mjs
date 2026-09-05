import test from "node:test";
import assert from "node:assert/strict";
import {mkdtemp,mkdir,writeFile,symlink} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {imports,scan} from "../dist/scan.js";
test("import evidence retains line numbers and handles scoped and attributed imports",()=>{
 assert.deepEqual(imports("// import Fake\n@testable import App\nimport struct Foundation.Date\n#if DEBUG\nimport OSLog\n#endif"),[{name:"App",line:2},{name:"Foundation",line:3},{name:"OSLog",line:5}]);
});
test("comments and string contents are not dependencies",()=>{
 assert.deepEqual(imports('/*\nimport Fake\n*/\nlet code = """\nimport Fiction\n"""\nimport SwiftUI'),[{name:"SwiftUI",line:7}]);
 assert.deepEqual(imports('/* outer /* nested */\nimport False\n*/\nimport Foundation'),[{name:"Foundation",line:4}]);
});
test("scanner groups real files, bounds evidence and ignores vendor/symlinks",async()=>{
 const root=await mkdtemp(join(tmpdir(),"reactor-test-"));
 await mkdir(join(root,"App","Views"),{recursive:true});await mkdir(join(root,"Vendor"));
 await writeFile(join(root,"App","Views","View.swift"),"import SwiftUI\nimport Foundation\n");
 await writeFile(join(root,"Vendor","Hidden.swift"),"import Hidden");
 await symlink(join(root,"Vendor"),join(root,"Linked"));
 const result=await scan(root);
 assert.equal(result.fileCount,1);assert.equal(result.nodes.length,3);
 assert.deepEqual(result.edges[0].evidence,[{path:"App/Views/View.swift",line:1}]);
 assert.equal(result.nodes[0].kind,"group");
});
test("relative paths fail and cancellation is propagated",async()=>{
 await assert.rejects(scan("."),/absolute/);
 const controller=new AbortController();controller.abort();
 await assert.rejects(scan(tmpdir(),controller.signal));
});
