// The texture view dimensions that webgpu.ts gives to WebGPU (REQ-GPU-034).
// events.test.ts imports this file, so CI runs it.
import { describe, expect, test } from 'bun:test';
import { VIEW_DIMENSIONS } from './webgpu';

describe('VIEW_DIMENSIONS', () => {
  test('each code of viewDimensionCode gives its WebGPU dimension', () => {
    expect(VIEW_DIMENSIONS[1]).toBe('1d');
    expect(VIEW_DIMENSIONS[2]).toBe('2d');
    expect(VIEW_DIMENSIONS[3]).toBe('2d-array');
    expect(VIEW_DIMENSIONS[4]).toBe('cube');
    expect(VIEW_DIMENSIONS[5]).toBe('cube-array');
    expect(VIEW_DIMENSIONS[6]).toBe('3d');
  });

  test('0 gives undefined, the dimension of the texture', () => {
    expect(0 in VIEW_DIMENSIONS).toBe(true);
    expect(VIEW_DIMENSIONS[0]).toBeUndefined();
  });
});
