---
title: "Build plan — cpp-concurrency-and-parallelism (r01)"
order: 1
---

# Build plan — `cpp-concurrency-and-parallelism`

> **STATUS 2026-10-10:** Phases 0 (scaffold), 1 (TOC), and 2a–2d (all 34 chapters) are
> DONE, each Opus-validated + repaired, committed on branch `docs/r01-scaffold`. Site builds
> clean. Phase 3 (examples) IN PROGRESS: 12 demos built+verified green on real Docker
> (ch1,3,4,5,6,7,8,9,10,15,18,20 — Conan+CMake+clang+UBI10+Lua verify.lua). Convention =
> `examples/concurrency/NN-slug/` (src/, conanfile, CMakeLists, Containerfile, verify.lua,
> demo.sh, README) + `scripts/test-concurrency-demo-NN.sh` + aggregator `scripts/verify-demos.sh`.
> Builds run SEQUENTIALLY (shared Conan cache/Docker/ports). TBB demos: conanfile needs
> `hwloc/*:shared=True` + Containerfile copies `.conan2` .so into runtime + LD_LIBRARY_PATH.
> ubi-minimal has coreutils-single (timeout), not full coreutils. NEXT: build wave B
> (ch2,14,17,21,32,34 authored), then wave C (ch11,12,13,24,25,27,28,29,33), then ch16 NUMA in
> KVM lab. Snippet-only (no demo): ch19,22,23,26,30,31. Nothing pushed (Gate A pending).

Approved via lgtm-relay (Opus plan → user review gate → execution). This file is the
resume artifact: update the phase table as work lands. Iteration branches (`docs/rNN-*`),
checkpoint commits, **never commit to `main`**.

## Decisions (fixed by user at the review gate 2026-10-09)
- **Source:** extract-and-re-point the C++ concurrency material from `~/Dev/linux-systems-programming`
  (seed = 15 chapters: Part 07 ch24–27, Part 11 ch39–41, Part 14 ch49–56). Part 11 is **only** 39/40/41;
  ch37/38 are `part: Observability` and were excluded from the raw seed.
- **Scope:** ~32 chapters in 8 parts + **one added "Observing Concurrency" chapter** (borrows lsp ch38
  OTel→LGTM) → **33 chapters** + appendix.
- **Examples:** pragmatic ~20–25 runnable demos (not strict one-per-chapter; conceptual chapters may
  share a demo or be snippet-only). Still honors "one or multiple per chapter" where a demo adds value.
- **Container engine:** Docker (req 22 → lgtm-docker-stack), matching the cpp-statelessness template.
- **Decks:** three — 100 (general), 101 (C++), 201 (low-latency/high-throughput). Full lgtm-presentation builds.
- **Concurrent REST (ch24):** minimal Boost.Asio/Beast standalone server. Concurrent gRPC (ch25) reuses
  the statelessness Conan+gRPC stack.
- **C++ standards:** C++20/23/26 shown via a ported `codetabs` include (`langs="C++20|C++23|C++26"`).
- **Audience:** HFT / low-latency / high-throughput engineers; never name companies in content.
- **Gates:** **Gate A** = repo create / push / Pages / hub PR (explicit approval). **Gate B** = source
  removal + re-point PR on linux-systems-programming (explicit approval, only after new site is live).

## Approach
Mirror the shipped `~/Dev/cpp-statelessness` site (collections docs/parts/examples/plans; Jekyll 4.3
Gemfile deviation; bespoke diagram palette cream #fdfbf7 / blue #4a73b8 / green #5a8870 / red #c0392b /
orange #a06030; `{% include excalidraw.html %}`; `scripts/lib/_helpers.sh` + per-demo CI scripts +
aggregator; `tools/` deck harness). Author a NEW C++-only TOC; **rewrite** the 15 seed chapters to a
professional 2–2.5k-word standard (seed prose is wordy — req 2/19); recast the source's C++/Go/Rust
codetabs as C++20/23/26. Ship incrementally across ~12 relay iterations.

## Proposed TOC (33 ch + appendix) — [S]=seed, [N]=new
- **P1 Foundations:** 1 Concurrency vs Parallelism[S] · 2 The Machine Underneath[N] · 3 Time/Timers/Deadlines[S] · 4 Threads in Modern C++[S]
- **P2 Shared State & Sync:** 5 Shared State & the Futex[S] · 6 Mutual Exclusion & Locking[N] · 7 Coordination Primitives[N] · 8 Atomics & the Memory Model[S] · 9 Lock-Free Data Structures[S]
- **P3 Tasks/Futures/Async:** 10 Futures/Promises/Packaged Tasks[N] · 11 Coroutines in Depth[S] · 12 Async Runtimes & Event Loops[S] · 13 Fibers & Stackful Coroutines[S]
- **P4 Parallelism & Throughput (VM-lab):** 14 Parallel Algorithms & Execution Policies[N] · 15 Thread Pools & Work Scheduling[N] · 16 NUMA/Affinity/Data Locality[N] · 17 SIMD & Data Parallelism[N]
- **P5 Low Latency & High Throughput:** 18 Benchmarking Without Deception[S] · 19 Low-Latency Fast Path[S] · 20 Mechanical Sympathy[N] · 21 Lock-Free Messaging & the Disruptor[N]
- **P6 Communications & Concurrency:** 22 Communication Models (sockets/pipes/D-Bus)[N] · 23 Actor Model & CSP Channels[N] · 24 Concurrent REST (Asio/Beast)[N] · 25 Concurrent gRPC[N]
- **P7 Correctness, Errors & Debugging:** 26 Error vs Exception Handling[N] · 27 Debugging Real Races & Deadlocks[N] · 28 Sanitizers & Dynamic Analysis[N] · 29 Observing Concurrency (OTel→LGTM)[N, added]
- **P8 Practice:** 30 Good Coding Practices[N] · 31 Design & Architecture Patterns[N] · 32 Concurrency in Containers[N] · 33 Capstone: Low-Latency Ingest→Match→Publish[S]
- **Appendix:** Build & Toolchain (clang/gdb/CMake/Conan/Lua `verify.lua`)

Every chapter: 2–2.5k-word body, "What we'll cover" open + "What we learned" close, ≥1 diagram, example
where it adds value, a container callout, a C++20/23/26 standards-delta note.

Reference books (bibliography): Williams *C++ Concurrency in Action 2e*; Grimm *Concurrency with Modern C++*;
Tanenbaum *Modern Operating Systems*; Son *High-Performance C++ Concurrency*; Lim *High-Performance C++26
Engineering*; Brandt *Parallel C++*; Kukov *Grokking Concurrency*.

## Phases (each = one relay iteration: Opus plan → Sonnet exec → Opus validate + user checkpoint)
| Phase | What | Skill | Status |
|-------|------|-------|--------|
| 0 | Scaffold: template skeleton + _config + Gemfile + layouts/includes + codetabs port + 8 _parts + bibliography + palette config | lgtm-jekyll | IN PROGRESS |
| 1 | TOC: all `_docs/NN-slug.md` stubs w/ front matter + section skeletons | lgtm-tutorial | TODO |
| 2a | Chapters P1–P2 (1–9) | lgtm-tutorial + voice | TODO |
| 2b | Chapters P3–P4 (10–17) | lgtm-tutorial + voice | TODO |
| 2c | Chapters P5–P6 (18–25) | lgtm-tutorial + voice | TODO |
| 2d | Chapters P7–P8 (26–33 + appendix) | lgtm-tutorial + voice | TODO |
| 3 | Examples (~20–25): Docker demos + Lua verify.lua; NUMA/parallel in KVM lab | lgtm-docker-stack, lgtm-systems-programming | TODO |
| 4 | Diagrams (≥1/chapter, bespoke palette) | lgtm-diagram-generator | TODO |
| 5 | Decks 100/101/201 | lgtm-presentation | TODO |
| 6 | Professional-voice sweep site-wide | lgtm-professional-voice | TODO |
| 7 | Hub linkage (patterncatalyst-workshops-tutorials-list, C++ group) | lgtm-jekyll | TODO |
| — | **GATE A** (repo/push/Pages/hub PR) | lgtm-github | gated |
| 8 | Source extract-and-re-point on linux-systems-programming | lgtm-github | TODO |
| — | **GATE B** (lsp removal + PR) | lgtm-github | gated |

## Acceptance (high level)
- Scaffold: `jekyll build` exits 0; 4 collections; `baseurl: /cpp-concurrency-and-parallelism`; codetabs
  switch C++20/23/26 and persist across pages.
- Chapters: 2,000–2,500-word bodies; standard open/close; ≥1 diagram + example link; container + standards notes.
- Debugging (req 24): ch27 reproduces a real race (TSan captured) and a real deadlock (gdb/Helgrind captured).
- VM safety (req 5): every NUMA/affinity/parallel demo runs in the KVM lab; none mutate host kernel/NUMA/governor.
- Extract/re-point: post-removal lsp link check finds zero dangling refs; former cross-links resolve to the live URL.

## Risks
Scope/size (phase strictly); VM/NUMA host-kernel safety (route via lgtm-systems-programming; grep demos for
host `/proc/sys`/`numactl`/`cpupower` writes); source-removal dangling links (re-point before delete, link-check
before/after); voice drift (apply voice skill during drafting); C++26 still evolving (compile every C++26 block,
label partial-support features); codetabs port fragility (visual check in Phase 0); diagram palette drift
(verify hex values in Phase 4).
