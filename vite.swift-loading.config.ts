import { defineConfig } from "vite";
import base from "./vite.config.js";

export default defineConfig({
  ...base,
  // Keep generated dependencies local when node_modules is shared by worktrees.
  cacheDir: new URL("./.build/vite-loading-cache", import.meta.url).pathname,
});
