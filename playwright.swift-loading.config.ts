import { defineConfig } from "@playwright/test";
import base from "./playwright.swift.config.js";

export default defineConfig({
  ...base,
  testMatch: "**/swift-loading.spec.ts",
  workers: 1,
  webServer: {
    command: "bunx vite --config vite.swift-loading.config.ts --host 127.0.0.1 --port 4287 --strictPort",
    url: "http://127.0.0.1:4287/block-editor/",
    reuseExistingServer: false,
  },
});
