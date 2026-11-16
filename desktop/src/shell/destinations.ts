import { lazy, type ComponentType, type LazyExoticComponent } from 'react';

export interface Destination {
  path: DestinationPath;
  label: string;
  /** The question the destination answers (docs/desktop/UX_ARCHITECTURE.md). */
  question: string;
  component: LazyExoticComponent<ComponentType>;
}

export type DestinationPath =
  | '/focus'
  | '/world'
  | '/office'
  | '/operations'
  | '/workspace'
  | '/library'
  | '/people'
  | '/insights'
  | '/terminal'
  | '/settings';

export const DESTINATIONS: readonly Destination[] = [
  {
    path: '/focus',
    label: 'Focus',
    question: 'What should we build together in this session?',
    component: lazy(() => import('../features/focus/FocusView')),
  },
];
