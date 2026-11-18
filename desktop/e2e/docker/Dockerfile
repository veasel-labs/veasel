# Isolated runner for the click-driven Focus journeys (docs/desktop/E2E_FOCUS_JOURNEYS.md).
#
# Arch is used (not a Playwright/Ubuntu image) because the V backend and the bun/TUI binaries
# under test are built on the host's current glibc (GLIBC_2.43); an Ubuntu 24.04 base ships 2.39
# and cannot run them. CI builds its own binaries on ubuntu and does not use this image.
#
# Base pinned by digest (archlinux:latest as pulled 2026-11-18).
FROM archlinux@sha256:d4594bb2300cba11f41c2f27923eb56f63d9988909c402f9c95517d1e362c899

RUN pacman -Syu --noconfirm --needed \
      nodejs git sqlite xorg-server-xvfb xorg-xauth \
      gtk3 nss alsa-lib libxss libxtst libdrm mesa at-spi2-core ttf-dejavu \
    && pacman -Scc --noconfirm \
    && rm -rf /var/cache/pacman/pkg/*

ENV NO_AT_BRIDGE=1 \
    VEASEL_E2E_NO_SANDBOX=1 \
    VEASEL_E2E_XVFB=1
WORKDIR /work/desktop
