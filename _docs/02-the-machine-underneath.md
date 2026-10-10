---
title: "The Machine Underneath"
order: 2
layout: tutorial
sectionid: docs
part: foundations
description: "The hardware concurrency sits on top of: cores, simultaneous multithreading, cache coherence, NUMA topology, and the scheduler's context-switch cost."
duration: "14 min"
---

<!-- PROVENANCE: NEW | anchor books: Tanenbaum, Williams -->

## What we'll cover

- Map the distinction between physical cores and SMT/hyperthreaded logical cores, and why that distinction changes thread-pool sizing decisions.
- Walk the cache hierarchy (L1/L2/L3) and the coherence protocol that keeps cached copies of shared data consistent across cores.
- Introduce NUMA topology: local vs remote memory nodes, and why a thread's physical placement affects latency before any lock is even involved.
- Quantify the cost of an OS context switch and when the scheduler decides to pay it.

## Cores, SMT, and Hyperthreading

<!-- TODO: cover physical vs logical cores and the effect of SMT on a CPU-bound thread pool -->

## The Cache Hierarchy and Coherence

<!-- TODO: cover L1/L2/L3 caches and the cache-coherence protocol (MESI or similar) in plain terms -->

## NUMA Topology

<!-- TODO: cover NUMA nodes, local vs remote memory access, and how topology is discovered at runtime -->

## The Scheduler and Context-Switch Cost

<!-- TODO: cover what the OS scheduler does on a context switch and the rough cost in cycles -->

## Running in a container

<!-- TODO: container callout — probing core count, cache sizes, and NUMA topology from inside a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
