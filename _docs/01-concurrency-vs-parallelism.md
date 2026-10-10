---
title: "Concurrency vs Parallelism"
order: 1
layout: tutorial
sectionid: docs
part: foundations
description: "The two independent axes of concurrency and parallelism, the four execution models that result, and how to measure them honestly."
duration: "12 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/49-concurrency-vs-parallelism.md | anchor books: Grokking Concurrency, Tanenbaum -->

## What we'll cover

- Separate the structural axis (concurrency: how work is organized) from the execution axis (parallelism: how work actually runs on hardware).
- Walk the four execution models that fall out of crossing those two axes, with a concrete C++ example for each.
- Distinguish observables that count real work (task completions, bytes processed) from clock-based measurements that can be fooled by the scheduler or the optimizer.
- Recast the comparison as C++-only, dropping the cross-language framing of the seed material in favor of std::thread, coroutines, and the parallel algorithms this book covers.

## The Two Axes: Structure vs Execution

<!-- TODO: cover why concurrency and parallelism are independent axes, with a 2x2 example grid -->

## The Four Execution Models

<!-- TODO: cover the four models that result from crossing the two axes, one short C++ snippet per model -->

## Observables That Are Counts, Not Clocks

<!-- TODO: cover why wall-clock timing alone misleads, and what counted observables (throughput, task counts) reveal instead -->

## Keeping the Comparison C++-Only

<!-- TODO: cover how this book narrows the seed material's cross-language comparison to a single-language, single-toolchain story -->

## Running in a container

<!-- TODO: container callout — running the four-model comparison program under the project's container setup -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
