---
title: "Chapter 14 — seq vs. par vs. par_unseq"
description: "The execution policy changes how an algorithm's work gets scheduled, never what the answer is."
order: 214
card_eyebrow: "Chapter · <strong>14</strong>"
card_title: "seq vs par vs par_unseq"
card_blurb: "The same sort and reduction run under std::execution::seq, par, and par_unseq against one fixed dataset. The sort hash and reduction sum must match exactly across all three policies; a CPU-usage probe reports, without asserting, whether par actually spread across cores."
layout: example
sectionid: examples
permalink: /examples/14-par-sort-reduce/
demo_dir: concurrency/14-par-sort-reduce
github_path: examples/concurrency/14-par-sort-reduce
---

> The full source for this example lives in [`examples/concurrency/14-par-sort-reduce/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/14-par-sort-reduce) — clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 14 — Parallel Algorithms and Execution Policies]({{ '/docs/14-parallel-algorithms-and-execution-policies/' | relative_url }})

## What it shows

One fixed pseudo-random dataset is sorted with `std::sort` and reduced with `std::transform_reduce` under `seq`, `par`, and `par_unseq`, hashing the sorted output and summing the reduction with an exactly associative integer combiner so the result is bit-identical regardless of evaluation order. The sort hash and reduction sum matching exactly across all three policies, every trial, is the hard assertion — any divergence is a correctness bug, independent of which policy ran faster. A `sched_getcpu()`-union technique records which CPUs the reduction actually touched; `par` using more than one CPU is reported as a soft signal, since the standard permits but does not require a parallel STL implementation to split any particular workload.

## Running it

```bash
cd examples/concurrency/14-par-sort-reduce
./demo.sh                 # build + run par_sort_reduce + verify.lua (--cpus=4)
./demo.sh --clean         # remove the image
```
