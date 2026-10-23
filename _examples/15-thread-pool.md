---
title: "Chapter 15: Single Shared Queue vs. Work-Stealing Deques"
description: "A single shared queue turns every worker into a competitor for one lock, and hardware_concurrency() never knows about a container's CPU quota."
order: 215
card_eyebrow: "Chapter · <strong>15</strong>"
card_title: "Shared Queue vs. Work-Stealing"
card_blurb: "A single-queue thread pool and a work-stealing pool run the identical CPU-bound task mix. A companion probe reads the real cgroup CPU quota from cpu.max and compares it against the raw host core count hardware_concurrency() reports."
layout: example
sectionid: examples
permalink: /examples/15-thread-pool/
demo_dir: concurrency/15-thread-pool
github_path: examples/concurrency/15-thread-pool
---

> The full source for this example lives in [`examples/concurrency/15-thread-pool/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/15-thread-pool): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 15: Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }})

## What it shows

Two pool designs run the same CPU-bound task mix: a single mutex-guarded deque every worker competes for, and a work-stealing pool where each worker owns its own deque, pushing and popping its own bottom and only occasionally stealing from a neighbor's top. Both pool kinds completing every submitted task exactly once, at low and high worker counts, is checked as a hard assertion independent of timing; work-stealing pulling ahead of the single queue once worker count rises is reported as a soft signal, since it needs a host with enough real cores to make the single lock actually contended. A second small binary reads `/sys/fs/cgroup/cpu.max` directly and prints the CPU-equivalent count the kernel will actually schedule onto, next to `hardware_concurrency()`, for comparison.

## Running it

```bash
cd examples/concurrency/15-thread-pool
./demo.sh            # build + run pool_bench/cgroup_probe + verify.lua
./demo.sh --clean    # remove the image
```
