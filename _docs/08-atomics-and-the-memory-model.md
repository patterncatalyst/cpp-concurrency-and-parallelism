---
title: "Atomics and the Memory Model"
order: 8
layout: tutorial
sectionid: docs
part: shared-state-and-synchronization
description: "std::atomic, the C++ memory model's ordering options, fences, and the real performance cost of stricter ordering."
duration: "16 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/26-atomics-and-lock-free.md | anchor books: Williams ch5, Grimm -->

## What we'll cover

- Introduce std::atomic<T> and what it guarantees beyond ordinary variable access.
- Walk the memory_order options: relaxed, acquire, release, acq_rel, and seq_cst, with the guarantee each one actually buys.
- Cover standalone fences and when they're needed independent of an atomic operation.
- Measure the real cost difference between relaxed and seq_cst ordering on common hardware.

## std::atomic and the Memory Model

<!-- TODO: cover what std::atomic guarantees and what it does not -->

## memory_order: relaxed, acquire, release, seq_cst

<!-- TODO: cover each ordering option with a minimal example that depends on it -->

## Fences

<!-- TODO: cover std::atomic_thread_fence and when a standalone fence is the right tool -->

## The Cost of Ordering

<!-- TODO: cover measured throughput differences between relaxed and seq_cst on the same workload -->

## Running in a container

<!-- TODO: container callout — running the ordering-cost microbenchmark and comparing results pinned vs unpinned in a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
