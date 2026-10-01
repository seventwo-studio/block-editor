import { defineConfig } from "@playwright/test";
import base from "./playwright.config.js";
export default defineConfig({
  ...base,
  testIgnore: [],
  testMatch: ["**/swift-wasm.spec.ts", "**/swift-selection.spec.ts", "**/runtime-compatibility.spec.ts"],
  use: { baseURL: "http://127.0.0.1:4287/block-editor/", headless: true },
  webServer: {
    command: "bun run demo:dev --port 4287 --strictPort",
    url: "http://127.0.0.1:4287/block-editor/",
    reuseExistingServer: false,
  },
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
    { name: "webkit", use: { browserName: "webkit" } },
    { name: "firefox", use: { browserName: "firefox" } },
  ],
});
