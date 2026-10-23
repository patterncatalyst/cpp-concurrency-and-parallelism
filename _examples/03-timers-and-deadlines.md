---
title: "Chapter 03: Deadline Propagation Across a Call Chain"
description: "Compute one deadline at the top of a call chain and pass that single time_point down through every hop, so no hop can silently extend the caller's budget."
order: 203
card_eyebrow: "Chapter · <strong>03</strong>"
card_title: "Deadline Propagation"
card_blurb: "A four-hop call chain shares one steady_clock deadline end to end. Injecting a slow hop anywhere in the chain still keeps the total wall-clock budget, and a hop entered past its deadline does no work at all."
layout: example
sectionid: examples
permalink: /examples/03-timers-and-deadlines/
demo_dir: concurrency/03-timers-and-deadlines
github_path: examples/concurrency/03-timers-and-deadlines
---

> The full source for this example lives in [`examples/concurrency/03-timers-and-deadlines/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/03-timers-and-deadlines); clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 3: Time, Timers, and Deadlines]({{ '/docs/03-time-timers-and-deadlines/' | relative_url }})

## What it shows

A runnable version of the chapter's four-function call chain computes a deadline once at the top and passes the identical `time_point` through every hop, each of which checks it before doing any work. One mode injects an artificial, deadline-aware delay at a chosen hop and proves the caller's total budget is never exceeded regardless of which hop is slow; a second mode calls a hop directly with an already-expired deadline and proves it returns immediately, with no work performed. A companion probe demonstrates that `steady_clock::now()` is a vDSO read under `strace`, while the one real sleep shows up as a kernel call: the chapter's cost argument made observable.

## Running it

```bash
cd examples/concurrency/03-timers-and-deadlines
./demo.sh            # build + run deadline_chain/clockprobe + verify.lua
./demo.sh --clean    # remove the image
```
