import { describe, expect, it } from 'vitest';
import { foldersToEntries } from './focus-folders';

describe('foldersToEntries', () => {
  it('names a folder after its last path segment', () => {
    expect(foldersToEntries(['/home/a/demo'])).toEqual([{ name: 'demo', target: '/home/a/demo', status: 'ok' }]);
  });

  it('disambiguates repeated names with the parent folder and drops duplicates', () => {
    const entries = foldersToEntries(['/w/one/app', '/w/two/app', '/w/one/app']);
    expect(entries.map((entry) => entry.name)).toEqual(['app (one)', 'app (two)']);
  });
});
