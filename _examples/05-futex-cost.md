---
title: "Chapter 05 — Uncontended vs. Contended Mutex Cost"
description: "An uncontended lock is a single atomic instruction that never leaves user space; a contended one crosses into the kernel, at orders of magnitude more cost."
order: 205
card_eyebrow: "Chapter · <strong>05</strong>"
card_title: "Futex Cost Under Contention"
card_blurb: "Baseline, uncontended, and contended modes run the identical counter increments. When strace is available, futex counts show the contended case crossing into the kernel far more often than the uncontended one, which should match the no-lock baseline."
layout: example
sectionid: examples
permalink: /examples/05-futex-cost/
demo_dir: concurrency/05-futex-cost
github_path: examples/concurrency/05-futex-cost
---

> The full source for this example lives in [`examples/concurrency/05-futex-cost/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/05-futex-cost) — clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 05 — Shared State and the Futex]({{ '/docs/05-shared-state-and-the-futex/' | relative_url }})

## What it shows

The same fixed number of counter increments runs three ways: no mutex at all, a `std::mutex` with no contention, and the identical mutex split across several threads that actually contend for it. Correctness — the final count matching the iteration count exactly — is checked as a hard assertion in all three modes, since contention is a performance concern, never a correctness one. Where `strace` and `ptrace` are available, the demo counts futex syscalls directly to show the uncontended lock reaching the kernel about as often as no lock at all, and the contended lock reaching it orders of magnitude more; where tracing is restricted, it falls back to a behavioral timing comparison instead of failing outright.

## Running it

```bash
cd examples/concurrency/05-futex-cost
./demo.sh            # build + run futex_cost (all three modes) + verify.lua
./demo.sh --clean    # remove the image
```
