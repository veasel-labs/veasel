#!/bin/sh
# Linux shell launcher for the pinned OpenCode benchmark. OpenCode itself runs
# outside this wrapper and can reach the loopback model proxy. Shell commands
# run in a separate network/PID namespace with a minimal environment.
set -eu

if [ "$(uname -s)" != Linux ]; then
	printf '%s\n' 'OpenCode shell sandbox requires Linux' >&2
	exit 69
fi

if [ "$#" -ne 2 ] || [ "$1" != -c ]; then
	printf '%s\n' 'expected OpenCode shell invocation: -c <command>' >&2
	exit 64
fi
command=$2

: "${VEASEL_REAL_TASK_ROOT:?VEASEL_REAL_TASK_ROOT is required}"
: "${VEASEL_REAL_TASK_PARENT:?VEASEL_REAL_TASK_PARENT is required}"
: "${VEASEL_BWRAP:?VEASEL_BWRAP is required}"

case "$VEASEL_BWRAP" in
	/*) ;;
	*) printf '%s\n' 'VEASEL_BWRAP must be an absolute path' >&2; exit 64 ;;
esac
if [ ! -x "$VEASEL_BWRAP" ] || [ -d "$VEASEL_BWRAP" ]; then
	printf '%s\n' 'VEASEL_BWRAP is not an executable file' >&2
	exit 69
fi

task_root=$(CDPATH='' cd -- "$VEASEL_REAL_TASK_ROOT" 2>/dev/null && pwd -P) || {
	printf '%s\n' 'VEASEL_REAL_TASK_ROOT must be an existing directory' >&2
	exit 64
}
task_parent=${task_root%/*}
task_name=${task_root##*/}
workspace_parent=$(CDPATH='' cd -- "$VEASEL_REAL_TASK_PARENT" 2>/dev/null && pwd -P) || {
	printf '%s\n' 'VEASEL_REAL_TASK_PARENT must be an existing directory' >&2
	exit 64
}
case "$workspace_parent" in
	/tmp|/tmp/*|/var/tmp|/var/tmp/*)
		printf '%s\n' 'VEASEL_REAL_TASK_PARENT must be persistent and outside temporary directories' >&2
		exit 64
		;;
esac
if [ "$task_parent" != "$workspace_parent" ]; then
	printf '%s\n' 'task workspace must be a direct child of VEASEL_REAL_TASK_PARENT' >&2
	exit 64
fi
parent_uid=$(/usr/bin/stat -c '%u' "$workspace_parent" 2>/dev/null) || {
	printf '%s\n' 'cannot verify workspace parent ownership' >&2
	exit 64
}
parent_mode=$(/usr/bin/stat -c '%a' "$workspace_parent" 2>/dev/null) || {
	printf '%s\n' 'cannot verify workspace parent permissions' >&2
	exit 64
}
if [ "$parent_uid" != "$(/usr/bin/id -u)" ] || [ "$parent_mode" != 700 ]; then
	printf '%s\n' 'workspace parent must be owned by the current user with mode 0700' >&2
	exit 64
fi
case "$task_name" in
	veasel-real-task-?*) ;;
	*) printf '%s\n' 'task workspace must use the veasel-real-task-* basename' >&2; exit 64 ;;
esac
hardlinked_file=$(/usr/bin/find -P "$task_root" -type f -links +1 -print -quit 2>/dev/null) || {
	printf '%s\n' 'cannot inspect all task workspace files for hard links' >&2
	exit 64
}
if [ -n "$hardlinked_file" ]; then
	printf '%s\n' 'task workspace contains a hard-linked regular file' >&2
	exit 64
fi
task_cwd=$(pwd -P)
case "$task_cwd" in
	"$task_root") relative_cwd= ;;
	"$task_root"/*) relative_cwd=${task_cwd#"$task_root"/} ;;
	*) printf '%s\n' 'shell working directory is outside VEASEL_REAL_TASK_ROOT' >&2; exit 64 ;;
esac

# Scrub the environment before bubblewrap starts: OpenCode's process may hold
# provider/proxy credentials. They must never reach the child command or its
# isolated /proc. The untrusted command remains a distinct argv element.
exec /usr/bin/env -i \
	PATH=/usr/bin:/bin \
	HOME=/root \
	LANG=C \
	TERM=dumb \
	"$VEASEL_BWRAP" \
	--unshare-all \
	--die-with-parent \
	--new-session \
	--dir /usr \
	--ro-bind /usr/bin /usr/bin \
	--ro-bind /usr/lib /usr/lib \
	--dir /usr/share \
	--dir /usr/share/git-core \
	--ro-bind-try /usr/share/git-core/templates /usr/share/git-core/templates \
	--symlink usr/bin /bin \
	--symlink usr/bin /sbin \
	--symlink usr/lib /lib \
	--symlink usr/lib /lib64 \
	--proc /proc \
	--dev /dev \
	--tmpfs /tmp \
	--dir /tmp/workspace \
	--tmpfs /run \
	--tmpfs /home \
	--tmpfs /root \
	--dir /root/tmp \
	--tmpfs /var/tmp \
	--bind "$task_root" /tmp/workspace \
	--chdir "/tmp/workspace${relative_cwd:+/$relative_cwd}" \
	--clearenv \
	--setenv PATH /usr/bin:/bin \
	--setenv HOME /root \
	--setenv TMPDIR /root/tmp \
	--setenv LANG C \
	--setenv TERM dumb \
	-- /bin/sh -c "$command"
