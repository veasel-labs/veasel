# Workspace confinement and delegated-child limits

Tracks veasel-labs/veasel#642 under epic #689.

## File edits and reads

Path-string checks (`path_is_within`, `os.is_link`) are advisory because a path
can change between the check and the use. Edits and reads therefore also go
through `workspace_confinement*.v`.

POSIX (Linux, macOS, other Unix):

- Every parent component is opened with `openat(..., O_DIRECTORY | O_NOFOLLOW)`.
  A symbolic link in any parent position fails; the final directory descriptor
  is pinned, so later renames or symlink swaps of its path cannot redirect the
  write.
- The leaf is opened with `O_NOFOLLOW | O_NONBLOCK`, `fstat`ed on the open
  descriptor, and must be a regular file. FIFOs, devices and directories are
  refused for reads and edits. Edits additionally require `st_nlink == 1`: a
  write through a hard link would modify a file that may live outside the
  tree. Reads of regular files with `st_nlink > 1` are allowed: a hard link
  grants the same user no read access they did not already have, and refusing
  it would break hardlink-based tooling such as pnpm `node_modules`. Size limits are enforced on
  the descriptor, so sparse and growing files stay bounded.
- Apply writes an `O_EXCL` temporary file and `renameat`s it through the pinned
  directory descriptor, then re-opens the result: dev/ino must match the file we
  wrote and (Linux) `/proc/self/fd/N` must still be inside the workspace root.
  A failed verification restores the original content (or unlinks a newly
  created file) and returns an error.

Windows: every component is screened for reparse points (symlinks, junctions)
with `GetFileAttributesW`. This is check-time only; Windows has no
descriptor-pinned replacement here, so the TOCTOU window is not closed there.

macOS: the descriptor-pinned walk and the post-write rollback are active, but
the post-write "directory still inside root" check needs `F_GETPATH` and is not
implemented; it is skipped.

## Protected and sensitive names

Never editable (any session): `.git`, `.hg`, `.svn`, `node_modules`, `vendor`,
compared case-insensitively and after folding trailing dots/spaces, NTFS
`:stream` suffixes and 8.3 short names (`GIT~1`).

Sensitive (git hooks, filter attributes, CI, shell environment):
`.gitattributes`, `.gitmodules`, `.husky`, `.github`, `.envrc`, `.git-hooks`,
`.githooks`, `.pre-commit-config.yaml`, plus any directory that
`core.hooksPath` points to inside a child worktree. Subagent integration never
turns these into parent proposals; they are reported as conflicts requiring
manual parent review. Parent users can still edit them directly.

## Delegated child commands (Linux Bubblewrap)

`run_linux_sandboxed_shell_command_with_write_scope` (a narrowed writable scope)
always applies: network namespace isolation (the caller's `allow_network` is
ignored), `--die-with-parent --new-session` plus PID namespace so timeout or
cancel tears down the whole tree including `setsid` escapes, the 64 KiB output
cap, `ulimit` caps (processes 256, open files 1024, file size, no core dumps),
and a 1 GiB worktree quota checked before and after the run. The primitive is
still not wired to the implementer profile.
