---
title: "Chapter 28 — One Race, Two Detectors; One Real Use-After-Free"
description: "The same data race is checked under ThreadSanitizer and Valgrind Helgrind, two structurally different detectors, and a real heap-use-after-free is caught by AddressSanitizer."
order: 228
card_eyebrow: "Chapter · <strong>28</strong>"
card_title: "Two Detectors, One Bug"
card_blurb: "The same racy counter is checked under ThreadSanitizer's compile-time instrumentation and Valgrind Helgrind's lockset/happens-before hybrid, two independent algorithms agreeing on one source line. A detached thread reading through a freed buffer is caught by AddressSanitizer, naming both the allocation and the free."
layout: example
sectionid: examples
permalink: /examples/28-sanitizers/
demo_dir: concurrency/28-sanitizers
github_path: examples/concurrency/28-sanitizers
---

> The full source for this example lives in [`examples/concurrency/28-sanitizers/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/28-sanitizers) — clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 28 — Sanitizers and Dynamic Analysis]({{ '/docs/28-sanitizers-and-dynamic-analysis/' | relative_url }})

## What it shows

The same racy, non-atomic counter from chapter 27 is built once plain, for Valgrind Helgrind to run against, and once with `-fsanitize=thread`; both detectors must report the race at the same `increment()` call site in `racy_counter.cpp`, and both must stay clean against the atomic `--mode fixed` build — two structurally different algorithms agreeing the bug is real, not an artifact of either tool's model. A separate program hands a raw pointer to a detached thread and frees the buffer on the main thread before the worker reads through it; AddressSanitizer must report the heap-use-after-free with both the allocating and freeing call stacks, and must never let the process reach its own completion print. Each sanitizer leg is a hard check whenever the environment lets it run, and a documented soft skip when a shadow-memory reservation or Valgrind's own startup fails under a restrictive container.

## Running it

```bash
cd examples/concurrency/28-sanitizers
./demo.sh            # build + run (TSan + Helgrind + ASan checks) + verify.lua
./demo.sh --clean    # remove the image
```
