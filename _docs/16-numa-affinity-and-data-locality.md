---
title: "NUMA, Affinity, and Data Locality"
order: 16
layout: tutorial
sectionid: docs
part: parallelism-and-throughput
description: "CPU pinning and affinity, NUMA-aware allocation, the latency gap between local and remote memory, and how cpuset constraints interact with it."
duration: "14 min"
---

<!-- PROVENANCE: NEW | anchor books: Son, Lim, Tanenbaum -->

## What we'll cover

- Cover setting CPU affinity for a thread and why pinning can help or hurt depending on the workload.
- Cover NUMA-aware allocation: placing memory on the node local to the thread that will use it most.
- Quantify the latency gap between local and remote NUMA memory access.
- Cover how a cpuset constrains which NUMA nodes and cores are visible to a process, and the interaction with a container's CPU limit.

## CPU Pinning and Affinity

<!-- TODO: cover sched_setaffinity and the trade-offs of pinning a thread to a core -->

## NUMA-Aware Allocation

<!-- TODO: cover numa_alloc_onnode and allocation policies that favor local memory -->

## Local vs Remote Memory Latency

<!-- TODO: cover measured latency differences between local and cross-node memory access -->

## cpuset and Container Interactions

<!-- TODO: cover how a cpuset cgroup restricts visible NUMA nodes and cores under orchestration -->

## Running in a container

<!-- TODO: container callout — running the NUMA locality benchmark under a cpuset-restricted container -->
<!-- TODO: VM-lab note — runs in the KVM lab via lgtm-systems-programming; never mutate host NUMA/governor -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
