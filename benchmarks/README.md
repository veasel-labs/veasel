# Benchmarks

`store_benchmark_test.v` measures a repeatable SQLite session round trip:
create a session, transactionally persist a user/assistant exchange, and read
back its messages and events. It uses V's production compiler mode and an
in-memory SQLite database so the sample isolates application/database work
from filesystem and network latency.

Run it from the repository root with the pinned V compiler:

```sh
VEASEL_RUN_BENCHMARK=1 VJOBS=1 v -prod test store_benchmark_test.v
```

Set `VEASEL_BENCH_ITERATIONS` to an integer from 1 to 10,000; the default is
500. Output is one JSON record with operations, iteration count, throughput,
and elapsed time. GitHub Actions retains the record for CI runs. Compare runs
on the same operating system and hardware; hosted-runner timings are noisy and
are reports, not a pass/fail performance promise.
