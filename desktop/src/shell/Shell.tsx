import { Suspense } from 'react';
import { HashRouter, Link, Navigate, Route, Routes, useLocation } from 'react-router';
import { useBackend, useHealth } from '../data/backend';
import { FocusProvider } from '../data/focus';
import { useVeaselFocusStore } from '../data/veasel-focus';
import { LiveProvider } from '../data/live';
import { TerminalProvider } from '../data/terminal';
import { DestinationBoundary, LoadingState, PixelIcon, ReceiptsProvider, type PixelIconName } from '../ui';
import { DESTINATIONS } from './destinations';
import { HOME_PATH } from './home';
import { useSessionContext } from './useSessionContext';
import styles from './shell.module.css';

function NavCount(_props: { path: string }) {
  return null;
}

function destinationIcon(path: string): PixelIconName {
  if (path === '/world') return 'world';
  if (path === '/providers') return 'projects';
  return 'focus';
}

function Hud() {
  const location = useLocation();
  const { backend } = useBackend();
  const health = useHealth();
  const { href } = useSessionContext();
  const version = health.data?.version ?? backend?.version ?? null;
  return (
    <nav className={styles.hud} aria-label="Destinations">
      <div className={styles.brand}>
        <span className={styles.brandMark} aria-hidden="true">
          V
        </span>
        <span className={styles.brandName}>Veasel</span>
        <span className={styles.brandTagline}>workshop</span>
      </div>
      <ul className={styles.navList}>
        {DESTINATIONS.map((destination) => (
          <li key={destination.path}>
            <Link
              to={href(destination.path)}
              className={`${styles.navLink}${location.pathname === destination.path ? ' active' : ''}`}
              title={destination.question}
              aria-current={location.pathname === destination.path ? 'page' : undefined}
            >
              <span className={styles.navIcon} aria-hidden="true">
                <PixelIcon name={destinationIcon(destination.path)} size={12} />
              </span>
              <span>{destination.label}</span>
              <NavCount path={destination.path} />
            </Link>
          </li>
        ))}
      </ul>
      <div className={styles.hudStatus}>
        <p className={styles.version}>{version ? `veasel ${version}` : 'Veasel'}</p>
      </div>
    </nav>
  );
}

function RedirectTo({ path }: { path: string }) {
  const { href } = useSessionContext();
  return <Navigate to={href(path)} replace />;
}

function ShellFrame() {
  const location = useLocation();
  return (
    <div className={styles.shell} data-destination={location.pathname}>
      <a className={styles.skipLink} href="#main">
        Skip to content
      </a>
      <Hud />
      <div className={styles.main}>
        <main id="main" className={styles.content} tabIndex={-1}>
          <Routes>
            <Route path="/" element={<RedirectTo path={HOME_PATH} />} />
            {DESTINATIONS.map(({ path, label, component: Destination }) => (
              <Route
                key={path}
                path={path}
                element={
                  <DestinationBoundary name={label}>
                    <Suspense fallback={<LoadingState label={`Opening ${label}`} />}>
                      <Destination />
                    </Suspense>
                  </DestinationBoundary>
                }
              />
            ))}
            <Route path="*" element={<RedirectTo path={HOME_PATH} />} />
          </Routes>
        </main>
      </div>
    </div>
  );
}

function ShellRoot() {
  const veaselStore = useVeaselFocusStore();
  if (!veaselStore) return <LoadingState label="Connecting to the Veasel backend" />;
  return (
    <FocusProvider store={veaselStore}>
      <ShellFrame />
    </FocusProvider>
  );
}

export default function Shell() {
  return (
    <HashRouter>
      <ReceiptsProvider>
        <LiveProvider>
          <TerminalProvider>
            <ShellRoot />
          </TerminalProvider>
        </LiveProvider>
      </ReceiptsProvider>
    </HashRouter>
  );
}
