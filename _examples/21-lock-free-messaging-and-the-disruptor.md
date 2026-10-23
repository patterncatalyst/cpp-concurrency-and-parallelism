---
title: "Chapter 21: Single-Producer Ring, Journal + Business-Logic Pipeline"
description: "A sequence barrier expresses fan-out and staged dependencies with nothing but atomic loads and comparisons, because every mutable position in the system has exactly one writer."
order: 221
card_eyebrow: "Chapter · <strong>21</strong>"
card_title: "Disruptor-Style Sequence Barrier"
card_blurb: "One producer feeds a journal consumer and a dependent business-logic consumer over a fixed-capacity ring. Every event is checked for in-order single-consumption, the dependent stage never reads ahead of the journal, and back-pressure engages deterministically."
layout: example
sectionid: examples
permalink: /examples/21-lock-free-messaging-and-the-disruptor/
demo_dir: concurrency/21-lock-free-messaging-and-the-disruptor
github_path: examples/concurrency/21-lock-free-messaging-and-the-disruptor
---

> The full source for this example lives in [`examples/concurrency/21-lock-free-messaging-and-the-disruptor/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/21-lock-free-messaging-and-the-disruptor): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 21: Lock-Free Messaging and the Disruptor]({{ '/docs/21-lock-free-messaging-and-the-disruptor/' | relative_url }})

## What it shows

One producer publishes slots on a fixed-capacity ring; a journal consumer trails the published sequence and naturally batches under load; a slowed business-logic consumer trails the journal's sequence rather than the producer's directly: the diamond-dependency sequence barrier lets the dependent stage never see an event the journal hasn't already processed. Every published event being consumed exactly once, in order, by both stages, the dependent stage never reading past the journal's own sequence, and the producer actually backing off at least once are all checked as hard assertions, since the business stage's fixed slowdown makes back-pressure a deterministic property of the run rather than a race against host speed. Throughput is reported, not asserted, since it depends on host core count and placement.

## Running it

```bash
cd examples/concurrency/21-lock-free-messaging-and-the-disruptor
./demo.sh            # build + run disruptor_ring + verify.lua
./demo.sh --clean    # remove the image
```
