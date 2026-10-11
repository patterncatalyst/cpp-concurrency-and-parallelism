# C++ Concurrency and Parallelism

![License](https://img.shields.io/badge/license-Apache%202.0-blue)
![C++](https://img.shields.io/badge/C%2B%2B-20%20%2F%2023%20%2F%2026-orange)
![Build](https://img.shields.io/badge/demos-28%20verified-brightgreen)
![Pages](https://img.shields.io/badge/site-live-success)

A **chapter-by-chapter, runnable account of concurrency and parallelism in modern
C++** for engineers who care about latency and throughput — the people building
matching engines, feed handlers, and other systems where a tail microsecond is a
defect. Every pattern is a C++20/23/26 program you can build and run, checked by a
Lua `verify.lua` that asserts the observable effect, not just a clean exit.

**[Read the book](https://patterncatalyst.github.io/cpp-concurrency-and-parallelism/)**

It is organized around one idea: concurrency is a correctness problem and
parallelism is a throughput problem, and the C++ tools for each — threads and
`jthread`, mutexes and the memory model, atomics and lock-free structures,
futures and coroutines, parallel algorithms, NUMA and mechanical sympathy, the
Disruptor, sanitizers, and tracing — compose into one low-latency
ingest → match → publish pipeline by the end.

## Structure

Ten parts (**Part 0** through **Part 9**), 33 chapters plus a prerequisites
chapter and a build appendix:

| Part | Topic |
|------|-------|
| 0 | Orientation — prerequisites and the Fedora reference setup |
| 1 | Foundations — concurrency vs parallelism, the machine underneath, time & deadlines, threads |
| 2 | Shared State and Synchronization — the futex, mutual exclusion, coordination primitives, atomics & the memory model, lock-free structures |
| 3 | Tasks, Futures, and Asynchrony — futures/promises, coroutines, async runtimes, fibers |
| 4 | Parallelism and Throughput — parallel algorithms, thread pools, NUMA & data locality, SIMD |
| 5 | Low Latency and High Throughput — benchmarking without deception, the fast path, mechanical sympathy, the Disruptor |
| 6 | Communications and Concurrency — communication models, actors & channels, concurrent REST, concurrent gRPC |
| 7 | Correctness, Errors, and Debugging — error vs exception handling, debugging real races & deadlocks, sanitizers, observing concurrency |
| 8 | Practice — coding practices, design patterns, concurrency in containers, the full ingest → match → publish example |
| 9 | Appendix — build & toolchain (clang / gdb / CMake / Conan / Lua) |

## Runnable examples

Twenty-eight self-contained demos under `examples/concurrency/`, each with its own
`README.md`, a `demo.sh`, and a `verify.lua`. Most build and run in a Docker
container (Conan + CMake + clang on UBI 10); the NUMA demo runs in a disposable
KVM guest because NUMA behavior cannot be shown truthfully in a container on a
single-node host. Correctness is asserted hard; latency is reported, not asserted
against a fixed threshold.

| Example | Demonstrates | Chapter |
|---------|--------------|---------|
| `examples/concurrency/06-lock-ordering` | An AB/BA deadlock, then a lock-ordering fix | 6 |
| `examples/concurrency/08-atomics-and-the-memory-model` | Memory-ordering effects, with a `--broken` negative case | 8 |
| `examples/concurrency/16-numa-affinity-and-data-locality` | `numa_alloc_onnode` placement, first-touch, cpuset fallback (KVM lab) | 16 |
| `examples/concurrency/20-mechanical-sympathy` | Padded vs unpadded counters — false sharing, measured | 20 |
| `examples/concurrency/21-lock-free-messaging-and-the-disruptor` | A single-producer ring with a journal + business-logic consumer | 21 |
| `examples/concurrency/27-debugging-races-deadlocks` | A real race caught by TSan and a real deadlock caught by gdb/Helgrind | 27 |
| `examples/concurrency/29-observing-concurrency` | An instrumented thread pool against a live LGTM stack (traces in Tempo, metrics in Mimir) | 29 |
| `examples/concurrency/33-ingest-match-publish` | The full pipeline under sustained load and an overload burst | 33 |

Run the whole suite, or one demo:

```bash
# one demo
cd examples/concurrency/20-mechanical-sympathy && ./demo.sh

# the aggregator (sequential, per-demo timeout)
./scripts/verify-demos.sh 20-mechanical-sympathy 21-lock-free-messaging-and-the-disruptor
```

## Diagrams and decks

- **39 figures** in `diagrams/` — paired `<name>.svg` (embedded in the site) and
  `<name>.excalidraw` (editable source), produced by `tools/generate_diagram.py`.
- **Three slide decks** in `presentation/`, built with the python-pptx harness
  (`tools/build-conc-decks.sh`):
  - `cpp-concurrency-100-mental-model.pptx` — the concepts, for a general audience
  - `cpp-concurrency-101-cpp-toolkit.pptx` — the modern C++ toolkit, code-first
  - `cpp-concurrency-201-low-latency.pptx` — the low-latency deep dive, with demo cues

## Stack

| Component | Role |
|-----------|------|
| C++20 / 23 / 26 | Shown side by side via a `codetabs` include |
| clang / gcc, CMake, Ninja | Build toolchain |
| Conan 2.x | Dependency management (fmt, Boost.Asio/Beast, gRPC, TBB, libnuma) |
| Docker Engine + UBI 10 | Container substrate for most demos |
| KVM / libvirt | Disposable guest for the NUMA demo (host is never modified) |
| Lua 5.4 | `verify.lua` assertion harness in every demo |
| gdb / Valgrind / TSan / ASan | The debugging and sanitizer chapters |
| `grafana/otel-lgtm` | Observability for the "Observing Concurrency" chapter |

## Repo map

```
_docs/         — the chapters (Jekyll docs collection): 00 prerequisites,
                 01–33 chapters, 34 build appendix
_parts/        — the ten parts (orientation … appendix)
_plans/        — the build plan and status
examples/      — 28 runnable demos (demo.sh + verify.lua each)
diagrams/      — 39 paired SVG + Excalidraw figures
presentation/  — the three decks + build notes
scripts/       — per-demo CI scripts, the verify-demos aggregator, shared helpers
tools/         — the diagram generator and the python-pptx deck harness
```

## Reference books

Williams, *C++ Concurrency in Action* (2e) · Grimm, *Concurrency with Modern C++*
· Tanenbaum, *Modern Operating Systems* · plus the high-performance and parallel
C++ titles cited in the [bibliography](https://patterncatalyst.github.io/cpp-concurrency-and-parallelism/bibliography/).

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
