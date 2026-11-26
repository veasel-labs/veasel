import type { LaidOutEntity } from './model/types';

const LABEL_EDGE_GUTTER = 8;
const LABEL_MAX_WIDTH = 192;

export type WorldLabelPositionInput = {
  entity: Pick<LaidOutEntity, 'x' | 'y' | 'w' | 'h' | 'name'>;
  zoom: number;
  pan: { x: number; y: number };
  viewport: { width: number; height: number };
  detail?: string;
  emphasized?: boolean;
};

export type WorldLabelPosition = { left: number; top: number; maxWidth?: number };

/**
 * Keep floating destination plaques inside the visible map viewport while the
 * map itself pans underneath them. Width is estimated from the same pixel font
 * size used by the plaque; this avoids DOM measurements and layout churn.
 */
export function worldLabelPosition({
  entity,
  zoom,
  pan,
  viewport,
  detail = '',
  emphasized = false,
}: WorldLabelPositionInput): WorldLabelPosition {
  const worldLeft = (entity.x + entity.w / 2) * zoom;
  const worldTop = (entity.y + entity.h) * zoom + 2;
  if (viewport.width <= 0 || viewport.height <= 0) return { left: worldLeft, top: worldTop };

  const fontSize = emphasized ? clamp(zoom * 0.4, 9, 14) : clamp(zoom * 0.34, 7, 12);
  const maxWidth = Math.max(1, Math.min(LABEL_MAX_WIDTH, viewport.width - LABEL_EDGE_GUTTER * 2));
  const textWidth = Math.min(maxWidth, (entity.name.length + detail.length * 0.75) * fontSize * 0.6 + 12);
  const halfWidth = Math.min(viewport.width / 2, textWidth / 2 + LABEL_EDGE_GUTTER);
  const minX = halfWidth;
  const maxX = Math.max(minX, viewport.width - halfWidth);
  const screenX = worldLeft + pan.x;
  const clampedX = clamp(screenX, minX, maxX);

  const lines = detail ? 2 : 1;
  const labelHeight = fontSize * 1.3 * lines + 8;
  const minY = LABEL_EDGE_GUTTER;
  const maxY = Math.max(minY, viewport.height - labelHeight - LABEL_EDGE_GUTTER);
  const screenY = worldTop + pan.y;
  const clampedY = clamp(screenY, minY, maxY);

  return { left: clampedX - pan.x, top: clampedY - pan.y, maxWidth };
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

