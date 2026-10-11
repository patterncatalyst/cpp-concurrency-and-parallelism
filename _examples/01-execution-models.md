---
title: "Chapter 01 — The Four Execution Models, Counted"
description: "Concurrency (structure) and parallelism (execution) are independent axes, so crossing them produces four real execution models, counted with observables instead of timed."
order: 201
card_eyebrow: "Chapter · <strong>01</strong>"
card_title: "Four Execution Models"
card_blurb: "Counts distinct CPUs touched, peak in-flight tasks, and interleaves across sequential, concurrent-pinned, parallel, and oversubscribed models — proof by observable, not by stopwatch."
layout: example
sectionid: examples
permalink: /examples/01-execution-models/
demo_dir: concurrency/01-execution-models
github_path: examples/concurrency/01-execution-models
---

> The full source for this example lives in [`examples/concurrency/01-execution-models/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/01-execution-models) — clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 1 — Concurrency vs Parallelism]({{ '/docs/01-concurrency-vs-parallelism/' | relative_url }})

## What it shows

The same instrumented workload runs under four models — sequential, concurrent-but-pinned-to-one-CPU, parallel-with-no-visible-threads, and an oversubscribed thread pool — and reports three counted observables per model: how many distinct CPUs it actually touched, the peak number of overlapping tasks, and how often two tasks' own sample points interleaved. That is the chapter's point made mechanical: concurrency (structure) and parallelism (execution) are independent, so "looks concurrent" and "ran in parallel" need separate proof. A Lua harness checks the sequential and concurrent-pinned cases as hard, environment-independent facts, and treats cross-CPU parallelism as a soft signal when the container's cpuset offers too few cores to show it.

## Running it

```bash
cd examples/concurrency/01-execution-models
./demo.sh            # build + run execution_models + verify.lua
./demo.sh --clean    # remove the image
```
