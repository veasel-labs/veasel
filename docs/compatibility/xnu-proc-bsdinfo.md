# XNU `proc_bsdinfo` owner identity probe

**Upstream:** [apple-oss-distributions/xnu](https://github.com/apple-oss-distributions/xnu)
**Inspected commit:** `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`
**Source:** `bsd/sys/proc_info.h`, `struct proc_bsdinfo`; `bsd/kern/proc_info.c`, `proc_pidinfo`
**License:** APSL-2.0

Veasel reads the macOS process start identity from `proc_pidinfo` using a local
V struct whose field order and widths match XNU's `struct proc_bsdinfo`. The
probe passes the struct by address to the API's `void *` output parameter and
checks the returned byte count before using the result. No XNU code is copied.

The inspected ABI has a 136-byte naturally aligned structure: process and
parent identifiers, status and flags, UID/GID fields, fixed-size command and
path buffers, and start-time fields. The local declaration intentionally
avoids C typedef lookup because XNU exposes this as a struct tag. Keep the
declaration synchronized with the pinned source if the layout changes.
