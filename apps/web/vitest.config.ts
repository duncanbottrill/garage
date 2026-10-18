// fileParallelism: false — test files share one local Postgres instance and some suites
// sweep every tesla_credentials row (refreshAll without ownerId), so running files
// concurrently lets one file's seeded rows bleed into another's assertions.
export default { test: { environment: "node", fileParallelism: false }, resolve: { alias: { "@": new URL("./src", import.meta.url).pathname } } };
