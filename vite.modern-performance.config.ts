import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
export default defineConfig({
  root: "tests/helpers", base: "/", publicDir: false,
  cacheDir: new URL("./.build/vite-performance-cache", import.meta.url).pathname,
  plugins: [react()],
  build: { outDir: "../../.build/modern-performance-web", emptyOutDir: true,
    rollupOptions: { input: new URL("./tests/helpers/modern-performance.html", import.meta.url).pathname } },
});
