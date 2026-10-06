import { test, expect } from '@playwright/test';

test.afterEach(async ({ page }, testInfo) => {
  if (testInfo.status !== testInfo.expectedStatus) await testInfo.attach('failed-editor-dom', { body: await page.content(), contentType: 'text/html' });
});

test('modern integrated editor preserves local writing through blocks, columns and paired reopen', async ({ page }, testInfo) => {
  test.setTimeout(120_000);
  await page.goto('modern.html');
  const title = page.getByRole('textbox', { name: 'Document title', exact: true });
  await expect(title).toBeVisible({ timeout: 30000 });
  await title.fill('Candidate Help'); await title.press('Enter');
  const body = page.getByRole('textbox', { name: 'Block text', exact: true }).first();
  await expect(body).toBeFocused(); await body.fill('Unicode 😀 and é');
  await body.press('End'); await body.press('Enter');
  const next = page.getByRole('textbox', { name: 'Block text', exact: true }).last();
  await next.fill('/code');
  await page.getByRole('option', { name: /Code/ }).click();
  const code = page.getByRole('textbox', { name: 'Code', exact: true });
  await expect(code).toBeFocused(); await code.fill('  literal 😀\n\tline'); await code.press('Tab');
  await expect(code).toContainText('literal 😀');
  await page.getByLabel('Code language').selectOption('swift');
  await page.getByRole('button', { name: 'Insert', exact: true }).click();
  await page.getByRole('textbox', { name: 'Search blocks' }).fill('table');
  await page.getByRole('option', { name: /Table/ }).click();
  await page.getByRole('textbox', { name: 'Table header', exact: true }).first().fill('Header');
  await page.getByRole('textbox', { name: 'Table cell', exact: true }).first().fill('Cell 😀');
  await page.getByRole('button', { name: 'Insert', exact: true }).click();
  await page.getByRole('textbox', { name: 'Search blocks' }).fill('columns');
  await page.getByRole('option', { name: /columns/i }).click();
  await expect(page.getByLabel('Column split')).toHaveValue('5000');
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.getByLabel('Column split')).toHaveValue('5000');
  await page.getByRole('button', { name: 'Save and retain local input' }).click();
  await page.reload(); await expect(title).toHaveText('Candidate Help', { timeout: 30000 });
  await expect(page.getByRole('textbox', { name: 'Block text', exact: true }).first()).toContainText('Unicode 😀 and é');
  await expect(page.getByLabel('Code language')).toHaveValue('swift');
  await expect(page.getByRole('textbox', { name: 'Table header', exact: true }).first()).toHaveText('Header');
  await expect(page.getByLabel('Column split')).toHaveValue('5000');
  await page.screenshot({ path: testInfo.outputPath('integrated-modern-editor.png'), fullPage: true });
});

test('cancelled slash query and app-owned media insertion retain the original editor', async ({ page }, testInfo) => {
  await page.goto('modern.html');
  const body = page.getByRole('textbox', { name: 'Block text', exact: true }).first();
  await expect(body).toBeVisible({ timeout: 30000 }); await body.fill('/imag');
  await page.getByRole('textbox', { name: 'Search blocks' }).press('Escape');
  await expect(body).toHaveText('/imag'); await expect(body).toBeFocused();
  await body.fill('/image'); await page.getByRole('option', { name: /Image/ }).click();
  await page.getByLabel('Choose local asset').setInputFiles({ name: 'tiny.png', mimeType: 'image/png', buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=', 'base64') });
  await expect(page.getByRole('img')).toBeVisible();
  await page.getByRole('textbox', { name: 'Image caption', exact: true }).fill('Local caption 😀');
  await page.getByRole('button', { name: 'Save and retain local input' }).click(); await page.reload();
  await expect(page.getByRole('textbox', { name: 'Image caption', exact: true })).toHaveText('Local caption 😀', { timeout: 30000 });
  await expect(page.getByRole('img')).toBeVisible();
  await testInfo.attach('local-media-reopen', { body: await page.screenshot(), contentType: 'image/png' });
});
