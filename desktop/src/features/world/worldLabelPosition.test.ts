import { describe, expect, it } from 'vitest';
import { worldLabelPosition } from './worldLabelPosition';

describe('worldLabelPosition', () => {
  it('keeps emphasized destination plaques inside the right and bottom viewport edges', () => {
    const position = worldLabelPosition({
      entity: { x: 20, y: 20, w: 2, h: 2, name: 'A very long destination name' },
      zoom: 16,
      pan: { x: -50, y: -80 },
      viewport: { width: 320, height: 220 },
      emphasized: true,
    });

    const screenLeft = position.left - 50;
    const screenTop = position.top - 80;
    expect(screenLeft).toBeLessThanOrEqual(240);
    expect(screenLeft).toBeGreaterThan(0);
    expect(screenTop).toBeLessThan(200);
    expect(screenTop).toBeGreaterThanOrEqual(8);
    expect(position.maxWidth).toBe(192);
  });

  it('limits plaque width to a narrow map viewport', () => {
    const position = worldLabelPosition({
      entity: { x: 5, y: 5, w: 2, h: 2, name: 'Workspace' },
      zoom: 16,
      pan: { x: -20, y: -10 },
      viewport: { width: 80, height: 80 },
    });

    expect(position.left - 20).toBeLessThan(48);
    expect(position.left - 20).toBeGreaterThan(32);
    expect(position.top - 10).toBeGreaterThanOrEqual(8);
    expect(position.maxWidth).toBe(64);
  });

  it('keeps a long selected resource label with detail inside a short viewport', () => {
    const position = worldLabelPosition({
      entity: { x: 3, y: 20, w: 2, h: 2, name: 'A very long selected resource name' },
      zoom: 32,
      pan: { x: -40, y: -620 },
      viewport: { width: 180, height: 100 },
      detail: 'waiting for approval',
      emphasized: true,
    });

    const screenLeft = position.left - 40;
    const screenTop = position.top - 620;
    const fontSize = Math.max(9, Math.min(14, 32 * 0.4));
    const maxLabelHeight = fontSize * 1.3 * 2 + 8;
    expect(screenLeft).toBeGreaterThanOrEqual(8);
    expect(screenLeft).toBeLessThanOrEqual(172);
    expect(screenTop).toBeGreaterThanOrEqual(8);
    expect(screenTop + maxLabelHeight).toBeCloseTo(92, 8);
    expect(position.maxWidth).toBe(164);
  });

  it('preserves world coordinates until the map viewport is measured', () => {
    const position = worldLabelPosition({
      entity: { x: 4, y: 3, w: 2, h: 2, name: 'Workshop' },
      zoom: 16,
      pan: { x: -30, y: -20 },
      viewport: { width: 0, height: 0 },
    });

    expect(position).toEqual({ left: 80, top: 82 });
  });
});
