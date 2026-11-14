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
case "$task_parent" in
	/tmp|/var/tmp) ;;
	*) printf '%s\n' 'VEASEL_REAL_TASK_ROOT must be a direct child of /tmp or /var/tmp' >&2; exit 64 ;;
esac
case "$task_name" in
	veasel-real-task-?*) ;;
	*) printf '%s\n' 'VEASEL_REAL_TASK_ROOT must use the veasel-real-task-* basename' >&2; exit 64 ;;
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
	PATH=/usr/local/bin:/usr/bin:/bin \
	HOME=/root \
	LANG=C \
	TERM=dumb \
	"$VEASEL_BWRAP" \
	--unshare-all \
	--die-with-parent \
	--new-session \
	--ro-bind / / \
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
	--setenv PATH /usr/local/bin:/usr/bin:/bin \
	--setenv HOME /root \
	--setenv TMPDIR /root/tmp \
	--setenv LANG C \
	--setenv TERM dumb \
	-- /bin/sh -c "$command"
