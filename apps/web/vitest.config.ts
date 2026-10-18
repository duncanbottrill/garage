export default { test: { environment: "node" }, resolve: { alias: { "@": new URL("./src", import.meta.url).pathname } } };
