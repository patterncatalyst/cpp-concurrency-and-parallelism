---
title: "The Low-Latency Fast Path"
order: 19
layout: tutorial
sectionid: docs
part: low-latency-and-high-throughput
description: "Three concrete moves that shrink tail latency: core pinning, buffer reuse, and zero allocation, plus the busy-poll versus block decision and kernel-bypass awareness."
duration: "14 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/40-low-latency-fastpath.md | anchor books: Son, Lim -->

## What we'll cover

- Cover three concrete moves that shrink the latency tail: pin a core, reuse one buffer, and allocate nothing on the hot path.
- Show why a pinned core's reported count can lie once it's inside a constrained container.
- Compare busy-polling (spend a whole core to avoid the scheduler round trip) against blocking and waking.
- Note where kernel-bypass networking fits into the fast-path picture, recast for a C++-only, service-level audience.

## Three Moves That Shrink the Tail

<!-- TODO: cover pinning, buffer reuse, and zero allocation as the three concrete fast-path moves -->

## Pinning a Core

<!-- TODO: cover affinity pinning and how a container's CPU limit changes what pinning actually buys -->

## Zero-Allocation Hot Paths

<!-- TODO: cover pre-allocating and reusing buffers to keep the hot path free of malloc -->

## Busy-Poll vs Block

<!-- TODO: cover the trade-off between busy-polling for lowest latency and blocking for lowest CPU cost, with a note on kernel bypass -->

## Running in a container

<!-- TODO: container callout — running the fast-path example pinned to a single container CPU and comparing busy-poll vs block latency -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
