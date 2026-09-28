import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  use: { baseURL: "http://127.0.0.1:4174/block-editor/", headless: true },
  webServer: {
    command: "bun run demo:dev --port 4174 --strictPort",
    url: "http://127.0.0.1:4174/block-editor/",
    reuseExistingServer: false,
  },
});
