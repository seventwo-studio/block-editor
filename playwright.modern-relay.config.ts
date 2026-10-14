import { defineConfig } from "@playwright/test";
import { browserLaunchOptions } from "./tests/helpers/browser-launch.js";
export default defineConfig({
  testDir: "./tests", testMatch: ["modern-relay.swift.ts", "modern-relay-client.swift.ts", "modern-relay-wire.swift.ts"], timeout: 120_000, workers: 1,
  use: { baseURL: "http://127.0.0.1:4290/block-editor/", headless: true },
  webServer: { command: "bun run demo:dev --port 4290 --strictPort", url: "http://127.0.0.1:4290/block-editor/", reuseExistingServer: false },
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
    { name: "webkit", use: { browserName: "webkit" } },
    { name: "firefox", use: { browserName: "firefox", launchOptions: browserLaunchOptions("firefox") } },
  ],
});
