import { fileURLToPath } from "node:url";

export default {
  transpilePackages: ["@garage/core"],
  // Monorepo root, so output file tracing never infers a root from a stray lockfile elsewhere.
  outputFileTracingRoot: fileURLToPath(new URL("../../", import.meta.url)),
};
