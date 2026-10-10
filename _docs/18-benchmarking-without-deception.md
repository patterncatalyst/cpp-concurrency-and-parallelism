---
title: "Benchmarking Without Deception"
order: 18
layout: tutorial
sectionid: docs
part: low-latency-and-high-throughput
description: "Warmup effects, coordinated omission, why percentiles beat the mean, and the microbenchmark pitfalls that make the compiler delete the work you meant to measure."
duration: "14 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/39-benchmarking-without-lies.md | anchor books: Son, Lim -->

## What we'll cover

- Show why a cold first call isn't a valid measurement, and what warmup actually needs to stabilize.
- Explain coordinated omission: the failure mode where a benchmark silently skips measuring the requests that couldn't even start.
- Argue for percentile-based reporting (p50/p99/p999) over a mean, with an example where the mean hides the real behavior.
- Cover microbenchmark pitfalls, particularly the compiler deleting unobserved work the benchmark thought it was timing.

## Warmup and Cold-Call Bias

<!-- TODO: cover why the first several iterations of a benchmark don't represent steady state -->

## Coordinated Omission

<!-- TODO: cover the request-that-never-started failure mode and how closed-loop benchmarks hide it -->

## Percentiles vs the Mean

<!-- TODO: cover an example distribution where the mean looks fine and the p99 does not -->

## Microbenchmark Pitfalls

<!-- TODO: cover compiler dead-code elimination of unobserved results and how to prevent it -->

## Running in a container

<!-- TODO: container callout — running the benchmark harness with a fixed CPU governor setting inside a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
