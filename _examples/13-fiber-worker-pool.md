---
title: "Chapter 13 — Fibers vs. Threads, and the Guard Page"
description: "A fiber and an OS thread are the same shape of worker at roughly two orders of magnitude different memory cost per unit."
order: 213
card_eyebrow: "Chapter · <strong>13</strong>"
card_title: "Fibers vs. Threads"
card_blurb: "One worker loop runs unmodified over Boost.Fiber fibers and over std::thread workers, comparing peak RSS for the same work. A separate guard-page demo turns a fiber stack overflow into an immediate, contained fault instead of silent memory corruption."
layout: example
sectionid: examples
permalink: /examples/13-fiber-worker-pool/
demo_dir: concurrency/13-fiber-worker-pool
github_path: examples/concurrency/13-fiber-worker-pool
---

> The full source for this example lives in [`examples/concurrency/13-fiber-worker-pool/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/13-fiber-worker-pool) — clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 13 — Fibers and Stackful Coroutines]({{ '/docs/13-fibers-and-stackful-coroutines/' | relative_url }})

## What it shows

One `worker_loop()` function, shared verbatim by both modes, pops work off a `boost::fibers::buffered_channel` — once run as Boost.Fiber fibers cooperatively sharing a single OS thread, and once run as independent `std::thread` workers — so the comparison is the same shape of worker at two different units of concurrency, not two different programs. Correctness and peak resident memory are both reported for each mode; the RSS gap is informational, not a fixed asserted ratio, since allocator behavior varies by host. A separate, safely contained piece forces an unbounded recursive function to walk into a fiber's `PROT_NONE` guard page inside a forked child process, producing an immediate, deterministic `SIGSEGV` instead of corrupting whatever memory happened to sit past the stack.

## Running it

```bash
cd examples/concurrency/13-fiber-worker-pool
./demo.sh            # build + run fiber_worker_pool (both modes + guard-page) + verify.lua
./demo.sh --clean    # remove the image
```
