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
  await page.getByRole('option', { name: /Simple table/ }).click();
  await page.getByRole('textbox', { name: 'Table header', exact: true }).first().fill('Header');
  await page.getByRole('textbox', { name: 'Table cell', exact: true }).first().fill('Cell 😀');
  await page.getByRole('button', { name: 'Insert', exact: true }).click();
  await page.getByRole('textbox', { name: 'Search blocks' }).fill('columns');
  await page.getByRole('option', { name: /^Two columns/ }).click();
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
  await page.getByLabel('Choose local asset').setInputFiles({ name: 'tiny.png', mimeType: 'image/png', buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==', 'base64') });
  await expect(page.getByRole('img')).toBeVisible();
  await page.getByRole('textbox', { name: 'Image caption', exact: true }).fill('Local caption 😀');
  await page.getByRole('button', { name: 'Save and retain local input' }).click(); await page.reload();
  await expect(page.getByRole('textbox', { name: 'Image caption', exact: true })).toHaveText('Local caption 😀', { timeout: 30000 });
  await expect(page.getByRole('img')).toBeVisible();
  await testInfo.attach('local-media-reopen', { body: await page.screenshot(), contentType: 'image/png' });
});

test('formatting keeps its captured Unicode selection and shared Undo', async ({ page }) => {
  await page.goto('modern.html');
  const body = page.getByRole('textbox', { name: 'Block text', exact: true }).first();
  await expect(body).toBeVisible({ timeout: 30000 }); await body.fill('Alpha 😀 omega');
  await body.evaluate(root => {
    const text = root.firstChild!; const selection = document.getSelection()!;
    selection.setBaseAndExtent(text, 0, text, 8);
  });
  await page.getByText('Format', { exact: true }).click();
  const bold = page.getByRole('button', { name: 'bold', exact: true });
  await expect(bold).toHaveAttribute('aria-pressed', 'false'); await bold.click();
  await expect(body.locator('strong')).toHaveText('Alpha 😀');
  await expect(body).toHaveText('Alpha 😀 omega');
  await page.getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(body.locator('strong')).toHaveCount(0); await expect(body).toHaveText('Alpha 😀 omega');
});
