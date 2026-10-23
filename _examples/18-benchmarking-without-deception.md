---
title: "Chapter 18: The Chapter's Own Harness, Checked Against Itself"
description: "This chapter's harness doesn't just describe warmup, coordinated omission, and percentiles: it implements all three against a trivial, fixed workload so every number traces back to an invariant."
order: 218
card_eyebrow: "Chapter · <strong>18</strong>"
card_title: "A Harness Checked Against Itself"
card_blurb: "A trivial atomic fetch_add workload is timed with warmup, per-iteration sampling, and percentile and coordinated-omission reporting in one mode, and with a single naive wall-clock measurement in another. The missing percentile fields in naive mode are the methodology gap made visible."
layout: example
sectionid: examples
permalink: /examples/18-benchmarking-without-deception/
demo_dir: concurrency/18-benchmarking-without-deception
github_path: examples/concurrency/18-benchmarking-without-deception
---

> The full source for this example lives in [`examples/concurrency/18-benchmarking-without-deception/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/18-benchmarking-without-deception): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 18: Benchmarking Without Deception]({{ '/docs/18-benchmarking-without-deception/' | relative_url }})

## What it shows

A single atomic `fetch_add` loop (too simple to have behavior of its own) is measured twice: once by the chapter's harness, which discards a warmup, times each iteration individually, sorts the samples for min/median/p99/max, and runs a coordinated-omission backfill over the run's own median; and once by a `--naive` mode that times the whole loop as one wall-clock sample with no percentiles computed at all. Every check is a hard assertion tied to the harness's own bookkeeping: percentile ordering, the coordinated-omission invariant that `co_p99` never falls below the raw `p99`, and a checksum matching the closed-form expected sum for that exact sequence of increments; never a specific nanosecond figure a host could make noisy. The naive mode's complete absence of percentile fields is itself a checked, observable property of which code path ran.

## Running it

```bash
cd examples/concurrency/18-benchmarking-without-deception
./demo.sh            # build + run bench (harness + --naive) + verify.lua
./demo.sh --clean    # remove the image
```
