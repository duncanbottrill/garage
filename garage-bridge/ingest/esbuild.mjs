import { build } from "esbuild";

await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  platform: "node",
  target: "node22",
  format: "esm",
  outfile: "dist/ingest.js",
  alias: { "@garage/core": process.env.CORE_PATH ?? "../../packages/core/src/index.ts" },
  banner: { js: "import { createRequire } from 'module'; const require = createRequire(import.meta.url);" },
});

console.log("ingest bundled");
