---
title: "Chapter 08: One-Slot Hand-off Under Three Orderings"
description: "Atomicity and ordering are two separate guarantees; seq_cst, acquire/release, and no ordering at all produce always-correct, correct-by-one-happens-before-edge, and broken outcomes."
order: 208
card_eyebrow: "Chapter · <strong>08</strong>"
card_title: "Atomics &amp; Memory Ordering"
card_blurb: "A one-slot producer/consumer hand-off runs under sequential consistency, under the minimal acquire/release pairing the hand-off actually needs, and under an unsynchronized mode. The first two always complete correctly; the third reliably stalls from a compiler hoisting a stale read out of the consumer's loop."
layout: example
sectionid: examples
permalink: /examples/08-atomics-and-the-memory-model/
demo_dir: concurrency/08-atomics-and-the-memory-model
github_path: examples/concurrency/08-atomics-and-the-memory-model
---

> The full source for this example lives in [`examples/concurrency/08-atomics-and-the-memory-model/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/08-atomics-and-the-memory-model); clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 8: Atomics and the Memory Model]({{ '/docs/08-atomics-and-the-memory-model/' | relative_url }})

## What it shows

One producer and one consumer move values through a single-slot hand-off under three synchronization modes: full sequential consistency, the chapter's minimal acquire/release pairing, and a broken mode using plain, non-atomic counters. Both correct modes must complete with the exact expected sum, every trial: a hard assertion, since the chapter is explicit that both orderings are sufficient. The broken mode is checked, also as a hard assertion, to actually misbehave: with no atomic and no volatile, the optimizer is free to hoist the consumer's read out of its spin loop, and the demo reliably stalls rather than relying on a classic, less reliable scheduling race. A soft timing check reports (without asserting a fixed percentage) that `seq_cst` pays measurably more than acquire/release for its stronger guarantee.

## Running it

```bash
cd examples/concurrency/08-atomics-and-the-memory-model
./demo.sh            # build + run ring_handoff (all three modes) + verify.lua
./demo.sh --clean    # remove the image
```
