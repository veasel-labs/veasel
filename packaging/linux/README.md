# Linux desktop entry

`veasel.desktop` registers Veasel Code as an on-demand user application
for desktop launchers — including HorneroOS shell's Apps provider, which
surfaces installed `.desktop` entries and launches them as user units
via app2unit (epic [#689](https://github.com/veasel-labs/veasel/issues/689),
HorneroOS/hornero#418).

Properties that matter for integration:

- `Exec=veasel` starts the normal CLI (backend + TUI). Nothing runs at
  login; there is no daemon and no `X-GNOME-Autostart-enabled`.
- `Terminal=true` because the shipped interface is the TUI; this flips
  only when a GUI build ships (issue #692).
- No `DBusActivatable`, no service files: Veasel is started and stopped
  by the user, zero cost when off, matching Hornero's M3 rules.

Installers should place this file at
`/usr/share/applications/veasel.desktop` (system) or
`~/.local/share/applications/veasel.desktop` (user). The icon entry is
intentionally omitted until a shipped icon asset exists — do not point
it at the CC-BY-NC mascot (see repo `THIRD_PARTY` notes).
