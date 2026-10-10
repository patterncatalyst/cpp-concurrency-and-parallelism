---
title: "Lock-Free Data Structures"
order: 9
layout: tutorial
sectionid: docs
part: shared-state-and-synchronization
description: "Single- and multi-producer/consumer ring buffers, the ABA problem, hazard pointers, RCU, and C++26's standardized reclamation support."
duration: "16 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/26-atomics-and-lock-free.md (lock-free portion) | anchor books: Williams ch7, Son -->

## What we'll cover

- Build an SPSC ring buffer and generalize the pattern toward MPMC, noting where the single-writer assumption breaks.
- Explain the ABA problem and why a naive compare-and-swap-based stack or queue is vulnerable to it.
- Cover hazard pointers and RCU (read-copy-update) as the two dominant safe-reclamation strategies.
- Preview C++26's standardized hazard_ptr and rcu facilities and how they relate to the hand-rolled versions.

## SPSC and MPMC Ring Buffers

<!-- TODO: cover the single-producer/single-consumer ring buffer and what changes moving to multi-producer/multi-consumer -->

## The ABA Problem

<!-- TODO: cover a concrete ABA scenario on a lock-free stack and why a plain CAS doesn't catch it -->

## Hazard Pointers and RCU

<!-- TODO: cover both safe-reclamation strategies and the trade-offs between them -->

## C++26 hazard_ptr and rcu

<!-- TODO: cover the standardized facilities and how they map onto the hand-rolled patterns above -->

## Running in a container

<!-- TODO: container callout — running the SPSC ring buffer throughput example under contended and uncontended container CPU limits -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
