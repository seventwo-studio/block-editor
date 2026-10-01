import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  testMatch: "**/*.spec.ts",
  testIgnore: ["**/swift-wasm.spec.ts", "**/swift-selection.spec.ts", "**/swift-loading.spec.ts", "**/runtime-compatibility.spec.ts", "**/relay-browser.spec.ts", "**/performance.spec.ts"],
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
    { name: "webkit", use: { browserName: "webkit" } },
  ],
  use: { baseURL: "http://127.0.0.1:4174/block-editor/", headless: true },
  webServer: {
    command: "bun run demo:dev --port 4174 --strictPort",
    url: "http://127.0.0.1:4174/block-editor/",
    reuseExistingServer: false,
  },
});
