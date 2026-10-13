import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { LaunchOptions } from "@playwright/test";

/** Firefox 155 still consults the installed Firefox application's data directory
 * even with a fresh -profile. macOS 27 protects that directory. Give only this
 * headless test process an empty application-data home; keep the shipped binary,
 * sandbox and macOS permissions unchanged. Remove after upgrading to the
 * upstream fix: https://github.com/microsoft/playwright/issues/42768. */
export function browserLaunchOptions(browserName: string): LaunchOptions {
  if (process.platform !== "darwin" || browserName !== "firefox") return {};
  const directory = mkdtempSync(join(tmpdir(), "editor-firefox-home-"));
  return { env: { ...process.env, CFFIXED_USER_HOME: directory } };
}
