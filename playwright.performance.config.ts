import { defineConfig } from '@playwright/test';
import runtime from './playwright.swift.config';
export default defineConfig({
  ...runtime,
  testMatch: ['**/performance.spec.ts'],
  workers: 1,
  fullyParallel: false,
});
