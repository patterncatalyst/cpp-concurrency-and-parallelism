---
title: "Chapter 07 — A Barrier-Phased Worker Pool"
description: "std::barrier's completion function is the natural place to merge per-thread partial results between phases, since the standard guarantees it runs exactly once per phase."
order: 207
card_eyebrow: "Chapter · <strong>07</strong>"
card_title: "Barrier-Phased Merge"
card_blurb: "A fixed worker pool runs barrier-synchronized rounds, each worker writing a deterministic value into its own slot before arriving. The completion function sums every slot with no extra lock, and the final total matches a closed-form expectation."
layout: example
sectionid: examples
permalink: /examples/07-coordination-primitives/
demo_dir: concurrency/07-coordination-primitives
github_path: examples/concurrency/07-coordination-primitives
---

> The full source for this example lives in [`examples/concurrency/07-coordination-primitives/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/07-coordination-primitives) — clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 07 — Coordination Primitives]({{ '/docs/07-coordination-primitives/' | relative_url }})

## What it shows

A fixed pool of workers runs through several `std::barrier`-synchronized phases; in each phase every worker writes into its own slot and arrives at the barrier, and the barrier's completion function merges all the slots into a running total before releasing everyone into the next phase. Because no two workers ever write the same slot, and the barrier itself establishes the happens-before edge between every write and the completion function's read, the merge needs no additional lock. The verifier checks that every phase produces exactly one completion line — never zero, never more than one — and that the final merged total matches an independently computed closed-form sum, both as hard assertions since a barrier's contract is a standard guarantee, not a race.

## Running it

```bash
cd examples/concurrency/07-coordination-primitives
./demo.sh            # build + run barrier_workers + verify.lua
./demo.sh --clean    # remove the image
```
