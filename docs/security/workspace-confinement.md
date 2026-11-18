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
cap, `prlimit` caps applied before exec, independent of the shell dialect (processes 256, open files 1024, file size 1 GiB, no core dumps; fails closed if prlimit is missing),
and a 1 GiB worktree quota checked before and after the run. 

### Wiring (#747)

Every shell command in a child session is routed through
`App.run_session_shell_command` (`subagent_child_shell.v`), used by both the
approval API and the autonomous path. A session that is the child of a subagent
run executes only through `run_delegated_child_shell_command`: writable scope is
the child worktree, network is denied, rlimits apply, and the cwd is validated
inside the worktree. The parent's `VEASEL_SHELL_ALLOW_UNSANDBOXED` opt-in is
never consulted for children, so a child can never run unsandboxed. On
platforms without Bubblewrap and `prlimit` (macOS, Windows, other) the command
is refused with no process started. The built-in implementer profile still
does not grant `workspace_propose_shell_command`; this wiring is the execution
guard for any path (API, future profile change) that creates a child shell
command, and it never widens inherited permissions.

## Platform validation matrix (#748)

Nothing below is claimed as verified on macOS or Windows beyond what the
cross-platform CI jobs execute. "Refuses" means no process starts and a typed
error names what is missing.

| Path | Linux | macOS | Windows | Code | Test that runs on Linux CI |
|---|---|---|---|---|---|
| Approved shell sandbox | Bubblewrap; refuses without `bwrap` unless the explicit opt-in | Seatbelt (`sandbox-exec`) when present, else refuses; runtime not validated here | AppContainer + Job when available, else refuses; runtime not validated here | `approved_shell_sandbox_plan`, `approved_shell_sandbox_refusal` (`shell_commands.v`) | `platform_validation_test.v`, `shell_commands_test.v` |
| Delegated child shell (network deny, narrowed writable scope, `prlimit`, quota) | Supported | Linux-only: refuses | Linux-only: refuses | `delegated_child_shell_refusal`, `run_delegated_child_shell_command` (`subagent_child_shell.v`) | `subagent_child_shell_test.v`, `platform_validation_test.v` |
| Descriptor-pinned edit/read walk (`O_NOFOLLOW`, regular-file and hardlink-write checks) | Supported | POSIX code path runs; not manually validated | Not present: reparse-point screening only (check-time, no TOCTOU closure) | `workspace_confinement_nix.c.v`, `workspace_confinement_windows.c.v` | `workspace_confinement_test.v` |
| Post-write "directory still inside root" verification | `/proc/self/fd` path | dev/ino identity against the expected directory path; fails closed when no path is supplied | Not applicable (no pinned descriptor) | `confined_dir_is_inside`, `confined_dir_matches_path` | `workspace_confinement_test.v` (`test_non_linux_directory_check_detects_swap_and_missing_path`) |
| `prlimit` resource limits | Required for child shell; refuses if missing | Not available: child shell refuses | Not available: child shell refuses | `child_shell_prlimit_args` | `subagent_resource_limits_test.v` |
| Stdio MCP sandbox | Same plan as shell (#746 / PR #754) | same | same | `mcp_stdio_sandbox_refusal` | see PR #754 |

Known residual gaps: Windows confinement is weaker than POSIX (no pinned
descriptor); macOS and Windows sandbox runtimes are exercised only by their CI
jobs and are not independently reviewed. Native macOS and Windows adversarial
tests are tracked in #748.
