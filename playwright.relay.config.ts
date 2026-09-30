import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./tests", testMatch: "relay-browser.spec.ts", timeout: 60_000, workers: 1,
  use: { baseURL: "http://127.0.0.1:4288/block-editor/", headless: true },
  webServer: [
    { command: "DEMO_TOKEN=relay-test DEMO_DATA=test-results/relay-data bun demo/relay/main.ts", port: 4319, reuseExistingServer: false },
    { command: "bun run demo:dev --port 4288 --strictPort", url: "http://127.0.0.1:4288/block-editor/", reuseExistingServer: false },
  ],
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
    { name: "webkit", use: { browserName: "webkit" } },
    { name: "firefox", use: { browserName: "firefox" } },
  ],
});
