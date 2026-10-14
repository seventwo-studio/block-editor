import { defineConfig } from "@playwright/test";
import { browserLaunchOptions } from "./tests/helpers/browser-launch.js";
export default defineConfig({
  testDir: "./tests", testMatch: "**/modern-wider.swift.ts", workers: 1, fullyParallel: false,
  timeout: 360_000, use: { baseURL: "http://127.0.0.1:4294/", headless: true, viewport: { width: 1280, height: 900 } },
  webServer: { command: "bun x vite preview --config vite.modern-performance.config.ts --host 127.0.0.1 --port 4294 --strictPort",
    url: "http://127.0.0.1:4294/modern-performance.html", reuseExistingServer: false },
  projects: ["chromium", "webkit", "firefox"].map(browserName => ({ name: browserName,
    use: { browserName: browserName as "chromium" | "webkit" | "firefox", launchOptions: browserLaunchOptions(browserName) } })),
});
