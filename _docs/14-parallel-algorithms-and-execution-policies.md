---
title: "Parallel Algorithms and Execution Policies"
order: 14
layout: tutorial
sectionid: docs
part: parallelism-and-throughput
description: "The standard execution policies, the parallel STL algorithms built on them, C++26 additions, and when parallel execution actually pays off."
duration: "13 min"
---

<!-- PROVENANCE: NEW | anchor books: Brandt, Lim -->

## What we'll cover

- Cover the three execution policies: seq, par, and par_unseq, and the guarantees each one relaxes.
- Survey the parallel STL algorithms available under an execution policy and how they differ from their sequential counterparts.
- Preview C++26 additions to the parallel algorithms library.
- Give a cost model for deciding when parallel execution pays off versus when it adds overhead without benefit.

## Execution Policies: seq, par, par_unseq

<!-- TODO: cover what each policy permits and forbids inside the algorithm's callable -->

## The Parallel STL

<!-- TODO: cover a representative set of parallel algorithms (transform, reduce, sort) and their sequential equivalents -->

## C++26 Additions

<!-- TODO: cover new parallel-algorithm additions landing in C++26 -->

## When Parallelism Pays Off

<!-- TODO: cover a simple cost model: data size, per-element work, and overhead crossover point -->

## Running in a container

<!-- TODO: container callout — running the parallel sort/reduce benchmark against varying container CPU limits -->
<!-- TODO: VM-lab note — runs in the KVM lab via lgtm-systems-programming; never mutate host NUMA/governor -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
