---
title: "Concurrency in Containers"
order: 32
layout: tutorial
sectionid: docs
part: practice
description: "cgroup CPU quota versus cpuset, why hardware_concurrency() lies inside a container, sizing pools to the real quota, and pinning under an orchestrator."
duration: "14 min"
---

<!-- PROVENANCE: NEW (adapted from cpp-statelessness/_docs/05-threading.md, 11-build-tooling.md) | anchor books: statelessness -->

## What we'll cover

- Distinguish a cgroup CPU quota (a time budget per period) from a cpuset (a fixed set of visible cores).
- Demonstrate concretely why std::thread::hardware_concurrency() reports the host's core count, not the container's quota.
- Cover deriving a correct pool size from the cgroup quota or an orchestrator-supplied CPU_LIMIT.
- Cover CPU pinning under an orchestrator and the interaction with cgroup and cpuset constraints.

## cgroup CPU Quota vs cpuset

<!-- TODO: cover the distinction between a time-sliced quota and a fixed core set -->

## Why hardware_concurrency() Lies in a Container

<!-- TODO: cover a concrete demonstration of the mismatch and its consequences for default pool sizing -->

## Sizing Pools to the Quota

<!-- TODO: cover reading the quota and deriving a correct thread or arena count from it -->

## Pinning Under Orchestration

<!-- TODO: cover how CPU pinning interacts with an orchestrator's own scheduling decisions -->

## Running in a container

<!-- TODO: container callout — running the cgroup-quota-detection example under progressively tighter --cpus limits -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
