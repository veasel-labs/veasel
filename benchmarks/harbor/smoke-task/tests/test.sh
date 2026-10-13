#!/bin/sh
set -eu
test "$(cat hello.txt)" = "Harbor adapter works."
test "$(find . -maxdepth 1 -type f | wc -l)" -eq 1
printf '1\n' > /logs/verifier/reward.txt
