---
title: "Chapter 33: Full Example: Ingest, Match, Publish"
description: "A real three-stage, low-latency pipeline wired together from the patterns earlier chapters spent 32 chapters establishing one at a time."
order: 233
card_eyebrow: "Chapter · <strong>33</strong>"
card_title: "Ingest / Match / Publish Pipeline"
card_blurb: "Multiple ingest producers feed a bounded MPMC ring into a single pinned matching thread running a real price-time-priority order book, which feeds a bounded multi-consumer ring to a publish pool. Sustained and overload load shapes prove conservation, single-writer discipline, and deterministic back-pressure."
layout: example
sectionid: examples
permalink: /examples/33-ingest-match-publish/
demo_dir: concurrency/33-ingest-match-publish
github_path: examples/concurrency/33-ingest-match-publish
---

> The full source for this example lives in [`examples/concurrency/33-ingest-match-publish/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/33-ingest-match-publish): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 33: Full Example: Ingest, Match, Publish]({{ '/docs/33-ingest-match-publish/' | relative_url }})

## What it shows

Several ingest producer threads generate a stream of order messages and push survivors onto a bounded multi-producer ring; a single thread, pinned to its own core, is the sole writer of a real price-time-priority limit order book and busy-polls the ring rather than blocking; a small publish pool drains the match stage's output ring. One `BoundedRing<T>` type, a generalized MPMC queue built on the single-writer-per-slot discipline earlier chapters established for simpler SPSC and disruptor rings, backs both hops. A sustained load phase keeps the ingest ring mostly empty while an unpaced overload burst reliably fills it; the verifier checks that no order is lost or duplicated through either ring, that order-book conservation holds exactly, that the match thread id never changes, and that back-pressure actually engaged under the burst: all hard assertions, with latency percentiles reported rather than pinned to a number.

## Running it

```bash
cd examples/concurrency/33-ingest-match-publish
./demo.sh            # build + run pipeline + verify.lua
./demo.sh --clean    # remove the image
```
