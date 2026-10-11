---
title: "Chapter 02 — Cache-Hierarchy Latency Probe"
description: "A random pointer-chase benchmark across five working-set sizes shows that memory-access cost tracks the cache hierarchy, not anything that looks like contention."
order: 202
card_eyebrow: "Chapter · <strong>02</strong>"
card_title: "Cache Hierarchy Latency"
card_blurb: "A single-threaded pointer-chase walks a random permutation at five working-set sizes from 8 KiB to 256 MiB. Latency rises monotonically as each step outgrows the next cache level."
layout: example
sectionid: examples
permalink: /examples/02-machine-underneath/
demo_dir: concurrency/02-machine-underneath
github_path: examples/concurrency/02-machine-underneath
---

> The full source for this example lives in [`examples/concurrency/02-machine-underneath/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/02-machine-underneath) — clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 02 — The Machine Underneath]({{ '/docs/02-the-machine-underneath/' | relative_url }})

## What it shows

A single-threaded benchmark builds a random single-cycle permutation over cache-line-sized nodes and times one link of the chase at five working-set sizes stepping from L1 up through DRAM. The permutation is random, not sequential, specifically so a hardware prefetcher has nothing to predict and the measurement stays a latency number rather than a bandwidth one. The hard assertion is ordering, not an absolute figure: latency must be monotonically non-decreasing as the working set grows past each cache level, since a bigger footprint can only match or lose to a smaller one. Exact nanosecond values and the DRAM/L1 ratio are reported for context, not asserted, since they depend on the host's real cache sizes.

## Running it

```bash
cd examples/concurrency/02-machine-underneath
./demo.sh            # build + run cache_latency + verify.lua
./demo.sh --clean    # remove the image
```
