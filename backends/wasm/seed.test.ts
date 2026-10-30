// The seed of the page URL (seed.ts, REQ-VOXEL-034).
//
//   bun test backends/wasm/seed.test.ts

import { describe, expect, test } from 'bun:test';
import { parseSeed, passSeed, seedFromQuery, U64_MAX } from './seed';

describe('parseSeed', () => {
  test('a decimal u64 is the seed', () => {
    expect(parseSeed('12345')).toEqual({ seed: 12345n, warning: null });
    expect(parseSeed('0')).toEqual({ seed: 0n, warning: null });
    expect(parseSeed('007')).toEqual({ seed: 7n, warning: null });
  });

  test('the largest u64 is the seed', () => {
    expect(parseSeed('18446744073709551615')).toEqual({
      seed: U64_MAX,
      warning: null,
    });
  });

  test('no parameter gives seed 0 with no warning', () => {
    expect(parseSeed(null)).toEqual({ seed: 0n, warning: null });
  });

  test('a value that is not a u64 gives seed 0 and a warning', () => {
    for (const bad of [
      '-1', // negative
      'abc', // not a number
      '12a',
      '0x10', // a prefix
      '1e3',
      ' 5', // a space
      '+5', // a sign
      '18446744073709551616', // too large
      '', // empty
    ]) {
      const r = parseSeed(bad);
      expect(r.seed).toBe(0n);
      expect(r.warning).toContain('is not a u64');
    }
  });

  test('the warning cuts a long value', () => {
    const r = parseSeed('x'.repeat(500));
    expect(r.warning?.length).toBeLessThan(200);
  });
});

describe('seedFromQuery', () => {
  test('reads the seed parameter', () => {
    const warn: string[] = [];
    expect(seedFromQuery('?seed=12345', (m) => warn.push(m))).toBe(12345n);
    expect(seedFromQuery('a=1&seed=9', (m) => warn.push(m))).toBe(9n);
    expect(seedFromQuery('', (m) => warn.push(m))).toBe(0n);
    expect(seedFromQuery('?other=1', (m) => warn.push(m))).toBe(0n);
    expect(warn).toEqual([]);
  });

  test('an invalid value warns one time', () => {
    const warn: string[] = [];
    expect(seedFromQuery('?seed=-3', (m) => warn.push(m))).toBe(0n);
    expect(warn.length).toBe(1);
    expect(seedFromQuery('?seed=', (m) => warn.push(m))).toBe(0n);
    expect(warn.length).toBe(2);
  });
});

describe('passSeed', () => {
  test('gives the seed as an i64 with the same bits', () => {
    const got: bigint[] = [];
    const exports = {
      swindowzig_set_seed: (s: bigint) => {
        got.push(s);
      },
    } as unknown as WebAssembly.Exports;
    expect(passSeed(exports, 12345n)).toBe(true);
    expect(passSeed(exports, U64_MAX)).toBe(true);
    expect(got).toEqual([12345n, -1n]);
    expect(BigInt.asUintN(64, got[1])).toBe(U64_MAX);
  });

  test('a wasm with no export ignores the seed', () => {
    expect(passSeed({} as WebAssembly.Exports, 5n)).toBe(false);
  });
});
