module main

import os
import time

const max_subagent_integration_paths = 256
const max_subagent_integration_listing_bytes = 1024 * 1024

pub struct SubagentIntegrationConflict {
pub:
	path   string
	reason string
}

pub struct SubagentIntegrationResponse {
pub:
	run_id    string
	status    string
	proposals []WorkspaceEditProposal
	conflicts []SubagentIntegrationConflict
}

struct SubagentIntegrationCandidate {
	path    string
	content string
}

// propose_subagent_integration creates ordinary parent workspace edit
// proposals. It never writes the parent checkout; users must approve each
// proposal through the existing workspace edit API.
fn (app &App) propose_subagent_integration(parent_session_id string,
	run_id string) !SubagentIntegrationResponse {
	mut store := app.store
	run := store.get_subagent_run(run_id)!
	if run.parent_session_id != parent_session_id {
		return error('child agent run not found')
	}
	if run.agent_id != 'implementer' {
		return error('only trusted implementer child changes can be integrated')
	}
	if run.status !in ['completed', 'failed', 'cancelled', 'uncertain'] {
		return error('child agent must reach a terminal state before integration review')
	}
	parent := store.get_session(parent_session_id)!
	child := store.get_session(run.child_session_id)!
	mut candidates := map[string]SubagentIntegrationCandidate{}
	mut conflicts := []SubagentIntegrationConflict{}
	mut conflicted_paths := map[string]bool{}
	mut inspected_paths := 0

	if run.workspace_ready {
		worktree := os.join_path(os.dir(os.real_path(store.path)), 'subagent-worktrees', run.id)
		if !os.is_dir(worktree) || os.real_path(child.directory) != os.real_path(worktree) {
			return error('child workspace is unavailable or no longer matches its durable run')
		}
		if worktree_changes := run_workspace_git_command_output(worktree,
			['diff', '--name-only', '-z', '--diff-filter=ACMRTUXB', run.workspace_base_commit,
				'--'],
			max_subagent_integration_listing_bytes) {
			for relative_path in worktree_changes.split('\0') {
				if relative_path.len == 0 {
					continue
				}
				inspected_paths++
				if inspected_paths > max_subagent_integration_paths {
					return error('child workspace change count exceeds the integration limit')
				}
				validate_subagent_relative_path(relative_path) or {
					conflicts << SubagentIntegrationConflict{
						path:   relative_path
						reason: 'child path is unsafe and cannot be integrated'
					}
					conflicted_paths[relative_path] = true
					continue
				}
				if file := resolve_workspace_edit_target(worktree, relative_path) {
					content := read_workspace_text_file(file) or {
						conflicts << SubagentIntegrationConflict{
							path:   relative_path
							reason: 'child file is not a bounded reviewable UTF-8 file'
						}
						conflicted_paths[relative_path] = true
						continue
					}
					if prior := candidates[relative_path] {
						if prior.content != content {
							conflicts << SubagentIntegrationConflict{
								path:   relative_path
								reason: 'child worktree and saved child proposal disagree for this file'
							}
							conflicted_paths[relative_path] = true
							candidates.delete(relative_path)
						}
					} else if !conflicted_paths[relative_path] {
						candidates[relative_path] = SubagentIntegrationCandidate{
							path:    relative_path
							content: content
						}
					}
				} else {
					conflicts << SubagentIntegrationConflict{
						path:   relative_path
						reason: 'child file path is unsafe or no longer readable'
					}
					conflicted_paths[relative_path] = true
				}
			}
		} else {
			return error('unable to inspect child worktree changes: ${err.msg()}')
		}
		if deletions := run_workspace_git_command_output(worktree,
			['diff', '--name-only', '-z', '--diff-filter=D', run.workspace_base_commit, '--'],
			max_subagent_integration_listing_bytes) {
			for relative_path in deletions.split('\0') {
				if relative_path.len > 0 {
					inspected_paths++
					if inspected_paths > max_subagent_integration_paths {
						return error('child workspace change count exceeds the integration limit')
					}
					conflicts << SubagentIntegrationConflict{
						path:   relative_path
						reason: 'file deletion requires explicit parent review and is not imported by this integration path'
					}
					conflicted_paths[relative_path] = true
					candidates.delete(relative_path)
				}
			}
		} else {
			return error('unable to inspect child file deletions: ${err.msg()}')
		}
		if untracked := run_workspace_git_command_output(worktree,
			['ls-files', '--others', '--exclude-standard', '-z'], max_subagent_integration_listing_bytes) {
			for relative_path in untracked.split('\0') {
				if relative_path.len == 0 || conflicted_paths[relative_path] {
					continue
				}
				inspected_paths++
				if inspected_paths > max_subagent_integration_paths {
					return error('child workspace change count exceeds the integration limit')
				}
				validate_subagent_relative_path(relative_path) or {
					conflicts << SubagentIntegrationConflict{
						path:   relative_path
						reason: 'child path is unsafe and cannot be integrated'
					}
					conflicted_paths[relative_path] = true
					continue
				}
				file := resolve_workspace_edit_target(worktree, relative_path) or {
					conflicts << SubagentIntegrationConflict{
						path:   relative_path
						reason: 'child file path is unsafe or no longer readable'
					}
					conflicted_paths[relative_path] = true
					continue
				}
				content := read_workspace_text_file(file) or {
					conflicts << SubagentIntegrationConflict{
						path:   relative_path
						reason: 'child file is not a bounded reviewable UTF-8 file'
					}
					conflicted_paths[relative_path] = true
					continue
				}
				parent_file := resolve_workspace_edit_target(parent.directory, relative_path) or {
					candidates[relative_path] = SubagentIntegrationCandidate{
						path:    relative_path
						content: content
					}
					continue
				}
				if !os.exists(parent_file) {
					candidates[relative_path] = SubagentIntegrationCandidate{
						path:    relative_path
						content: content
					}
					continue
				}
				parent_content := read_workspace_text_file(parent_file) or {
					conflicts << SubagentIntegrationConflict{
						path:   relative_path
						reason: 'parent file cannot be safely compared with the child snapshot'
					}
					conflicted_paths[relative_path] = true
					continue
				}
				if parent_content == content {
					continue // Copied untracked parent snapshot, unchanged by the child.
				}
				conflicts << SubagentIntegrationConflict{
					path:   relative_path
					reason: 'child changed a file that was untracked in the parent snapshot; its original contents are unavailable for safe conflict detection'
				}
				conflicted_paths[relative_path] = true
			}
		} else {
			return error('unable to inspect child untracked files: ${err.msg()}')
		}
	}

	// Include proposals saved in the child session by the implementer under the
	// normal ask policy. These proposals are data only; importing them still
	// creates a separate parent proposal requiring explicit review and approval.
	store.mu.lock()
	child_proposals := store.db.exec_param_many("SELECT path, content FROM workspace_edits WHERE session_id = ? AND status = 'pending' ORDER BY created_at, id",
		[run.child_session_id]) or {
		store.mu.unlock()
		return error('unable to read child edit proposals')
	}
	store.mu.unlock()
	for row in child_proposals {
		path := row.val(0)
		if conflicted_paths[path] {
			continue
		}
		validate_subagent_relative_path(path) or {
			conflicts << SubagentIntegrationConflict{
				path:   path
				reason: 'child proposal path is unsafe and cannot be integrated'
			}
			conflicted_paths[path] = true
			continue
		}
		if prior := candidates[path] {
			if prior.content != row.val(1) {
				conflicts << SubagentIntegrationConflict{
					path:   path
					reason: 'child worktree and saved child proposal disagree for this file'
				}
				conflicted_paths[path] = true
				candidates.delete(path)
			}
		} else {
			candidates[path] = SubagentIntegrationCandidate{
				path:    path
				content: row.val(1)
			}
		}
	}

	mut paths := candidates.keys()
	paths.sort()
	mut proposals := []WorkspaceEditProposal{}
	for path in paths {
		if conflicted_paths[path] {
			continue
		}
		candidate := candidates[path]
		matches_base := workspace_git_path_matches_commit(parent.directory, run.workspace_base_commit,
			path) or {
			conflicts << SubagentIntegrationConflict{
				path:   path
				reason: 'parent file differs from the child base snapshot or cannot be safely inspected'
			}
			continue
		}
		if !matches_base {
			conflicts << SubagentIntegrationConflict{
				path:   path
				reason: 'parent file differs from the child base snapshot; resolve the conflict before integration'
			}
			continue
		}
		draft := prepare_workspace_edit(parent.directory, path, candidate.content) or {
			conflicts << SubagentIntegrationConflict{
				path:   path
				reason: 'parent file is not safe to review: ${err.msg()}'
			}
			continue
		}
		proposal := store.create_or_reuse_pending_workspace_edit(parent_session_id, draft) or {
			conflicts << SubagentIntegrationConflict{
				path:   path
				reason: 'unable to save parent proposal: ${err.msg()}'
			}
			continue
		}
		proposals << proposal
	}
	return SubagentIntegrationResponse{
		run_id:    run.id
		status:    run.status
		proposals: proposals
		conflicts: conflicts
	}
}

fn workspace_git_path_matches_commit(root string, commit string, relative_path string) !bool {
	validate_subagent_relative_path(relative_path)!
	if !valid_git_object_id(commit) {
		return error('child base snapshot is unavailable')
	}
	resolve_workspace_edit_target(root, relative_path) or { return false }
	entry := run_workspace_git_command_output(root,
		['ls-tree', '--name-only', '-z', commit, '--', relative_path], 8_192)!
	if entry.len == 0 {
		target := os.join_path(root, relative_path.replace('/', os.path_separator))
		if os.exists(target) {
			return false
		}
	}
	return run_workspace_git_command_exit_code(root, ['diff', '--quiet', commit, '--', relative_path])! == 0
}

fn run_workspace_git_command_exit_code(checkout string, args []string) !int {
	git := os.find_abs_path_of_executable('git') or {
		return error('git executable is not available')
	}
	mut process := os.new_process(git)
	process.set_args(args)
	process.set_work_folder(checkout)
	process.set_redirect_stdio()
	process.run()
	started := time.now()
	for process.is_alive() {
		if time.since(started) > workspace_git_command_timeout {
			process.signal_kill()
			process.wait()
			process.close()
			return error('git worktree command timed out')
		}
		time.sleep(10 * time.millisecond)
	}
	process.wait()
	code := process.code
	stderr := process.stderr_slurp().trim_space()
	process.close()
	if code !in [0, 1] {
		return error(if stderr.len > 512 { stderr[..512] } else { stderr })
	}
	return code
}
