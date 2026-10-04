import path from "node:path";
import { createRequire, Module } from "node:module";

process.env.NODE_PATH = path.join(process.cwd(), "node_modules", "next", "dist", "compiled");
Module._initPaths();
const require = createRequire(import.meta.url);
require("../.test-build/tests/domain.test.js");
