---
title: "Chapter 20: False Sharing vs. Cache-Line Padding"
description: "Two threads that touch completely disjoint data can still serialize on each other if that data shares a 64-byte cache line."
order: 220
card_eyebrow: "Chapter · <strong>20</strong>"
card_title: "False Sharing &amp; Padding"
card_blurb: "Two pinned threads each increment their own atomic counter, with and without cache-line padding between the two counters. Correctness holds either way, but the unpadded layout runs measurably slower from coherence traffic on a line neither thread actually shares."
layout: example
sectionid: examples
permalink: /examples/20-mechanical-sympathy/
demo_dir: concurrency/20-mechanical-sympathy
github_path: examples/concurrency/20-mechanical-sympathy
---

> The full source for this example lives in [`examples/concurrency/20-mechanical-sympathy/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/20-mechanical-sympathy): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 20: Mechanical Sympathy]({{ '/docs/20-mechanical-sympathy/' | relative_url }})

## What it shows

Two threads, pinned to separate CPUs, each `fetch_add` their own atomic counter N times, with a `--pad` flag choosing whether the two counters sit on the same 64-byte cache line or each get their own `hardware_destructive_interference_size`-aligned line. Both counters reaching the exact expected total is checked as a hard assertion in both layouts, since false sharing is a performance bug, never a correctness one; the padded run averaging measurably faster than the unpadded run is checked as a soft assertion against a noise floor, since the effect's size depends on the two threads actually landing on separate physical cores. This is the reference example the rest of the project's directory shape, `verify.lua` contract, and `demo.sh` contract are copied from.

## Running it

```bash
cd examples/concurrency/20-mechanical-sympathy
./demo.sh            # build + run false_sharing (both modes) + verify.lua
./demo.sh --clean    # remove the image
```
