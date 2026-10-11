---
title: "Build plan — cpp-concurrency-and-parallelism (r01)"
order: 1
---

# Build plan — `cpp-concurrency-and-parallelism`

 > **STATUS 2026-10-10 (checkpoint before compact):** Phases 0,1,2 DONE (34 chapters, Opus-validated).
> **NEW: added `_docs/00-prerequisites.md`** (Fedora-focused setup chapter, order 0, orientation part;
> renders+builds clean) and an **Editors note in ch34** (any CMake editor; **CLion preferred**).
> **Fedora is the reference platform** (user directive) — prereqs use `dnf`; demos build in UBI10.
> All committed on branch `docs/r01-scaffold`. Nothing pushed (Gate A pending).
>
> **PHASE 3 COMPLETE — 28/28 demos VERIFIED GREEN.** 27 Docker demos on real Docker (Conan+CMake+clang+
> UBI10+Lua verify.lua, each `./demo.sh` exit 0): ch1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,17,18,20,21,
> 24,25,27,28,29,32,33,34 — PLUS ch16 NUMA verified in the KVM lab (see below). (ch27 debugging + ch28
> sanitizers: gdb/TSan/valgrind/ASan fire for REAL, req 24 met.)
>
> **PHASE 4 COMPLETE — 39/39 diagrams rendered.** In-repo recolored generator `tools/generate_diagram.py`
> (bespoke palette: cream #fdfbf7 / blue #4a73b8 / green #5a8870 / orange #a06030 / red #c0392b / ink #1a1a1a /
> dark-arrow #2d2d2d; styles box/blue/green/orange/red/ink/sub/kernel/ghost; edges default dark + `heat=True`
> red). All 39 SVG+Excalidraw pairs in `diagrams/<name>.{svg,excalidraw}` (one per excalidraw include), jekyll
> build publishes them to `_site/diagrams/`. Done via relay (Opus grammar+reference 16-first-touch-misplacement;
> 6 Sonnet batches A–F; Opus validation: all parse, no amber, cream bg, contact-sheet visual check).
>
> **PHASE 5 COMPLETE — 3 decks (commit c278899).** python-pptx harness ported from cpp-statelessness
> as a pure library `tools/build-pptx.py` (parameterized `FOOTER_LABEL`, repointed paths/URLs), plus
> `tools/convert-diagrams.sh` (diagrams/*.svg → /tmp/diagrams-png/*.jpg via soffice+pdftoppm) and
> `tools/build-conc-decks.sh [100|101|201|all]`. Three decks, each = `sections_conc_NNN.py` + entry
> script `build-conc-NNN-pptx.py` → `presentation/cpp-concurrency-NNN-*.pptx`: **100** mental model
> (36 slides, diagram-forward), **101** C++ toolkit (54, code-heavy C++20/23/26), **201** low-latency
> deep dive (62, +8 demo cues to verified demos). Relay: 3 Sonnet authors (parallel) → Opus validate
> (clean rebuild exit 0, notes on every slide, 0 missing-diagram placeholders, demo dirs exist, 3
> contact-sheet visual QA) → 1 Sonnet voice-repair round (36 edits; ban-tier confessional/filler/meta
> → 0; 21 sanctioned survivors: bug-case "deliberately", idiom "for free", "Capstone" title). Decks +
> sources + build-notes committed (statelessness precedent tracks .pptx). **NEXT: Phase 6 (site-wide
> professional-voice sweep — note the "capstone" rename is a book-wide decision to make there).**
>
> **PHASE 6 COMPLETE — professional-voice sweep.** Reader-facing surface (md/py/svg) now clean:
> genuine/genuinely, confessional (honest/plainly/worth-stating), meta-narration ("rest of the
> book/deck"), and reassurance ("for real") all at 0. Sanctioned survivors kept: bug-case/forced-condition
> "deliberately" (~42) and idiomatic "for free"/"on purpose" (~22). Done via relay: 4 Sonnet executors
> (chapters 00–15 / 16–25 / 26–34 / READMEs+parts+build-comments) + Opus triage/validate; deck sources
> and the ch33 demo dir swept by hand. Code-comment prose in demo `.cpp` files left as-is (outside the
> voice skill's default surface). **User decision (2026-10-11): "capstone" removed book-wide INCLUDING
> identifiers** — `33-capstone-ingest-match-publish` → `33-ingest-match-publish` (dir + doc slug + CI
> script), C++ target `capstone_pipeline` → `pipeline`, env `CAPSTONE_*` → `PIPELINE_*`; ch33 re-verified
> locally (built+ran+verify.lua PASS on re-run; one intermittent occupancy-assert flake observed, not a
> regression — see below). ch33/part-08 titles → "Full Example…". PROVENANCE comments keep real lsp source
> filenames. Jekyll build clean, new slug resolves, zero dangling old-slug refs, 3 decks rebuilt+validated.
>
> **KNOWN FLAKE (ch33):** verify.lua can intermittently fail with `ingest_peak_occupancy (65) exceeded
> ingest_capacity (64)` under the overload burst — a benign measurement race in sampling peak occupancy of
> the MPSC ingest ring (not memory corruption; re-run passes). Predates the rename. Candidate fix: tolerate
> peak==capacity+1 in verify.lua, or tighten the peak-occupancy counter's memory ordering in pipeline.cpp.
>
> **STANDING POLICY CHANGE (2026-10-11, user):** new projects of our own → create the remote (public)
> FIRST, then branch, then work (off-device durability); tutorials default to the workshops/tutorials hub
> but always ask. Encoded in lgtm-github/jekyll/tutorial skills (lgtm-skills branch `docs/project-bootstrap-policy`,
> synced locally, NOT pushed) + memory feedback_remote_first_bootstrap. **This makes Gate A (create the
> cpp-concurrency remote) the policy-aligned next move — but still asked, since it's outward-facing.**
>
> **NEXT: Phase 7 (hub linkage) — and per the new policy, create the GitHub remote for THIS project (Gate A).**
> **ch29 observing-concurrency DONE (commit 631e271):** three fixes — (a) static otel-archive link cycle
> (`undefined reference to opentelemetry::sdk::common::Base64Escape`) resolved with a CMAKE_CXX_LINK_EXECUTABLE
> `--start-group/--end-group` wrapper, same as ch25 (LINK_GROUP:RESCAN does NOT work: Conan exposes the otel
> components as INTERFACE targets, so the group markers are dropped and CMake reports a self-cycle); (b) lgtm
> healthcheck used wget but the grafana/otel-lgtm image (RHEL9) ships only curl → switched to curl; (c)
> exit-time SIGSEGV in MeterContext::Shutdown() from the global Provider's static shared_ptr torn down during
> exit() static destruction → clear the global trace/meter providers before main returns (as opentelemetry-cpp's
> own examples do). verify.lua PASSES live: 24 traces in Tempo w/ correct cross-thread span nesting (root→3
> children each), pool_queue_depth saturation metric in Mimir (max 54). Diagnosed the segfault with a throwaway
> Release+`-g` gdb image (the real build strips); backtrace pinned it to __run_exit_handlers.
> **PHASE 3 COMPLETE — ch16 NUMA VERIFIED (commit 2fc776e).** Self-contained KVM-lab demo (NOT Docker):
> `src/numa_locality.cpp` (libnuma + sched_setaffinity), `verify.lua`, `provision-numa-vm.sh` (2 NUMA cells via
> `--cpu host-passthrough,cell0..,cell1..`, `--print-xml`-validated; dedicated lab key; cache at `$HOME/cpp-conc-lab`
> 0755), minimal `cloud-init/`, `cpuset-run.sh` (raw cgroup v2 cpuset), `demo.sh`, `LAB-NETWORKING.md`. verify.lua
> PASSES on a 2-node guest: numa_alloc_onnode placement (both nodes), first-touch binding (both nodes), cpuset.mems=0
> → numa_alloc_onnode(1) silently falls back to node 0. Timing SOFT (ratio ~1.0 — host is single-NUMA-node so QEMU
> emulates topology not latency; user-approved placement-HARD/timing-SOFT).
>   - **THREE host-environment gotchas hit + solved (all in LAB-NETWORKING.md):** (1) ssh auth OK then hangs =
>     GNOME-keyring/gcr ssh-agent GUI sign dialog → use a dedicated passphrase-less lab key + `IdentityAgent=none`
>     (now in scripts); (2) guest can't reach internet (dnf hangs) = Docker sets FORWARD policy DROP → user ran
>     `sudo iptables -I FORWARD -i/-o virbr0 -j ACCEPT`; (3) first-touch landed on wrong node = sched_setaffinity
>     migration race → spin until sched_getcpu() on target node before touching. VPN was a red herring (broke too,
>     but issue persisted with it off). Diagnosed guest internals OFFLINE with libguestfs (virt-cat/virt-log).
>   - **Guest left running** (`cpp-conc-numa`, reused across runs); `./demo.sh --clean` destroys it. The FORWARD
>     iptables rule is not persistent — a Docker restart may re-break guest networking (re-run the iptables line).
> Snippet-only chapters (no demo, intentional): ch19,22,23,26,30,31.
>
> **Build mechanics:** builds run SEQUENTIALLY (shared Conan cache/Docker/port 50051). Aggregator
> `scripts/verify-demos.sh <names...>` now has a hard per-demo `timeout` (DEMO_TIMEOUT, default 2700s).
> Template to copy = `examples/concurrency/20-mechanical-sympathy/`. Lessons baked in: TBB needs
> `hwloc/*:shared=True` + runtime .so copy; Boost.Fiber needs context+filesystem+atomic+system enabled;
> gRPC uses the cpp-statelessness static recipe + start-group linker; ubi-minimal = coreutils-single (timeout);
> demos that run a server/signal must target the server PID directly (not a wrapping subshell); verify.lua
> runs INSIDE the container, correctness HARD / timing SOFT.
>
> **AFTER Phase 3:** Phase 4 diagrams (~40 DIAGRAM SPEC comments embedded in chapters; bespoke palette),
> 5 decks (100/101/201), 6 professional-voice sweep (em-dash thinning + stray "simply"), 7 hub linkage,
> GATE A (repo create/push — needs explicit OK), 8 source extract-and-re-point from linux-systems-programming
> (GATE B). User cadence: check in at each phase boundary.

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
- **P8 Practice:** 30 Good Coding Practices[N] · 31 Design & Architecture Patterns[N] · 32 Concurrency in Containers[N] · 33 Full Example: Low-Latency Ingest→Match→Publish[S]
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
| 3 | Examples (~20–25): Docker demos + Lua verify.lua; NUMA/parallel in KVM lab | lgtm-docker-stack, lgtm-systems-programming | DONE (28/28: 27 Docker + ch16 NUMA) |
| 4 | Diagrams (≥1/chapter, bespoke palette) | lgtm-diagram-generator | DONE (39/39, tools/generate_diagram.py) |
| 5 | Decks 100/101/201 | lgtm-presentation | DONE (36/54/62 slides, commit c278899) |
| 6 | Professional-voice sweep site-wide | lgtm-professional-voice | DONE (reader surface clean; ch33 "capstone" renamed to "full example" incl. ids) |
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
