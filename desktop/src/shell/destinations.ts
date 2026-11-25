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
  | '/providers'
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
  {
    path: '/world',
    label: 'World',
    question: 'Where is everything, and what is actually happening?',
    component: lazy(() => import('../features/world/WorldView')),
  },
  {
    path: '/providers',
    label: 'Providers',
    question: 'Which installed tools and workspace capabilities can Veasel use?',
    component: lazy(() => import('../features/providers/ProvidersView')),
  },
];
