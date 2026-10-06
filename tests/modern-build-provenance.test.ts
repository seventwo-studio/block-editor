import { test, expect } from 'bun:test';
// @ts-ignore Build receipt scripts are deliberately plain JavaScript.
import { sameSourceInputs } from '../scripts/record-modern-build.mjs';

test('provenance compares every source digest independently of enumeration order', () => {
  expect(sameSourceInputs({ a: 'one', b: 'two' }, { b: 'two', a: 'one' })).toBe(true);
  expect(sameSourceInputs({ a: 'one', b: 'two' }, { b: 'changed', a: 'one' })).toBe(false);
  expect(sameSourceInputs({ a: 'one', b: 'two' }, { a: 'one' })).toBe(false);
  expect(sameSourceInputs({ a: 'one' }, { a: 'one', b: 'two' })).toBe(false);
});
