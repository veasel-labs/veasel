import { expect, test } from '@playwright/test';
import { waitForBackend, type Desktop } from './fixtures';
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
