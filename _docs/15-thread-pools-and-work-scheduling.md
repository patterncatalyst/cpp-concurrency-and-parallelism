---
title: "Thread Pools and Work Scheduling"
order: 15
layout: tutorial
sectionid: docs
part: parallelism-and-throughput
description: "Sizing a thread pool correctly, work-stealing task queues, and the cgroup-aware sizing a pool needs to behave inside a container."
duration: "14 min"
---

<!-- PROVENANCE: NEW (adapted from cpp-statelessness/_docs/05-threading.md, linux-systems-programming/_docs/41-capstone-fleet.md) | anchor books: Son, Williams -->

## What we'll cover

- Establish a sizing rule for a thread pool based on workload type (CPU-bound vs I/O-bound) rather than a fixed guess.
- Cover work-stealing as a load-balancing strategy across per-thread task queues.
- Cover single-queue versus per-thread-queue designs and their contention trade-offs.
- Make the pool size cgroup-aware so it reflects the container's CPU quota rather than the host's core count.

## Sizing a Thread Pool

<!-- TODO: cover sizing rules for CPU-bound versus I/O-bound workloads -->

## Work-Stealing

<!-- TODO: cover a work-stealing deque design and when it outperforms a single shared queue -->

## Task Queues

<!-- TODO: cover single shared queue versus per-thread queues and the contention each implies -->

## cgroup-Aware Sizing in Containers

<!-- TODO: cover reading the cgroup CPU quota at startup and sizing the pool from it instead of hardware_concurrency() -->

## Running in a container

<!-- TODO: container callout — running the pool-sizing benchmark under a constrained --cpus limit and observing throughput plateau at the quota -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
