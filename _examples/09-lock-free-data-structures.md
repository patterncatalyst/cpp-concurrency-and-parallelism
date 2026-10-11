---
title: "Chapter 09 — SPSC Ring Buffer"
description: "A single-producer/single-consumer ring buffer is safe without a lock because each counter has exactly one writer."
order: 209
card_eyebrow: "Chapter · <strong>09</strong>"
card_title: "SPSC Ring Buffer"
card_blurb: "A single-producer/single-consumer ring buffer is checked per item, not just by aggregate sum, for loss, duplication, and reordering across capacities and padding settings. A padded head/tail layout shows the throughput cost of two unrelated counters sharing one cache line."
layout: example
sectionid: examples
permalink: /examples/09-lock-free-data-structures/
demo_dir: concurrency/09-lock-free-data-structures
github_path: examples/concurrency/09-lock-free-data-structures
---

> The full source for this example lives in [`examples/concurrency/09-lock-free-data-structures/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/09-lock-free-data-structures) — clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 9 — Lock-Free Data Structures]({{ '/docs/09-lock-free-data-structures/' | relative_url }})

## What it shows

One producer pushes values into a bounded ring and one consumer pops them, with `tail` written only by the producer and `head` written only by the consumer — the single-writer-per-counter property that lets the ring run with no lock at all. Correctness is checked per logical position, not just by a summed total, across both padding settings and capacities down to one slot, the chapter's maximum-contention case; a lost or duplicated item is caught immediately rather than possibly canceling out in an aggregate sum. A soft timing check reports that padding `head` and `tail` onto separate cache lines should raise throughput, since an unpadded layout has the consumer's write to `head` invalidate the producer's cached `tail` even though the producer never touches `head`.

## Running it

```bash
cd examples/concurrency/09-lock-free-data-structures
./demo.sh            # build + run spsc_ring (correctness sweep + timing) + verify.lua
./demo.sh --clean    # remove the image
```
