import { expect, test } from '@playwright/test';
import { setViewport, waitForBackend, type Desktop } from './fixtures';
import { launchFocusDesktop, stopSpawnedClis } from './journey-env';

/**
 * World acceptance on real runtime state (#693): a real Focus thread
 * appears as a project house with a character in the World; activating
 * the character opens that SAME thread in Focus; deleting the thread
 * removes it from the World. No fake activity is ever rendered.
 */
async function createThread(page: Desktop['page'], directory: string, title: string): Promise<string> {
  return page.evaluate(
    async ({ directory, title }) => {
      const response = await fetch('/v1/sessions', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ title, directory }),
      });
      if (!response.ok) throw new Error(`create session failed: ${response.status}`);
      const session = (await response.json()) as { id: string };
      return session.id;
    },
    { directory, title },
  );
}

async function deleteThread(page: Desktop['page'], id: string): Promise<void> {
  await page.evaluate(async (sessionId) => {
    await fetch(`/v1/sessions/${sessionId}`, { method: 'DELETE' });
  }, id);
}

test('a real thread appears in the World, opens in Focus, and disappears when deleted', async () => {
  const { desktop, env } = await launchFocusDesktop();
  try {
    const { page } = desktop;
    await waitForBackend(page);
    const threadId = await createThread(page, env.repo, 'World journey thread');
    // The thread store loads at app start; reload so it refetches and the
    // World projection includes the new thread.
    await page.reload();
    await waitForBackend(page);

    const nav = page.getByRole('navigation', { name: 'Destinations' });
    await nav.getByRole('link', { name: 'World' }).click();
    const world = page.getByRole('application', { name: 'Semantic workspace world' });
    await expect(world).toBeVisible();

    const house = world.getByRole('button', { name: /focus-fixture · Project/ });
    await expect(house).toBeVisible({ timeout: 20_000 });
    const character = world.getByRole('button', { name: /World journey thread/ });
    await expect(character).toBeVisible({ timeout: 20_000 });

    // Activating the character opens the same thread in Focus.
    await character.click();
    await expect(page.getByText('World journey thread').first()).toBeVisible({
      timeout: 20_000,
    });

    // Ending the session removes it from the World (no fake activity).
    await deleteThread(page, threadId);
    await nav.getByRole('link', { name: 'World' }).click();
    await expect(world.getByRole('button', { name: /World journey thread/ })).toHaveCount(0, {
      timeout: 20_000,
    });
  } finally {
    await desktop.close();
    await stopSpawnedClis(env);
  }
});

test('the live-data status stays visible without intercepting World map input', async ({}, testInfo) => {
  const { desktop, env } = await launchFocusDesktop();
  try {
    const { page } = desktop;
    await page.route('**/v1/operations/latest*', (route) =>
      route.fulfill({ status: 503, contentType: 'application/json', body: '{"error":"temporary outage"}' }),
    );
    await waitForBackend(page);
    await page.getByRole('navigation', { name: 'Destinations' }).getByRole('link', { name: 'World' }).click();

    const status = page
      .getByRole('status')
      .filter({ hasText: 'Some live runtime details are unavailable; missing activity is omitted.' });
    await expect(status).toBeVisible({ timeout: 20_000 });
    await setViewport(desktop.app, 1024, 640);

    const hitTarget = await status.evaluate((element) => {
      const bounds = element.getBoundingClientRect();
      const point = document.elementFromPoint(
        bounds.left + Math.min(bounds.width / 2, 20),
        bounds.top + bounds.height / 2,
      );
      return point?.closest('[role="application"]')?.getAttribute('aria-label') ?? null;
    });
    expect(hitTarget).toBe('Semantic workspace world');
    await testInfo.attach('world-live-data-status-compact.png', {
      body: await page.screenshot(),
      contentType: 'image/png',
    });
  } finally {
    await desktop.close();
    await stopSpawnedClis(env);
  }
});
