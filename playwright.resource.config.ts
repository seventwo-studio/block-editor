import { defineConfig } from '@playwright/test';
import runtime from './playwright.swift.config';
export default defineConfig({ ...runtime, testMatch: ['**/writing-resource.swift.ts'], workers: 1, fullyParallel: false });
