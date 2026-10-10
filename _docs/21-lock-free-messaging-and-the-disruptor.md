---
title: "Lock-Free Messaging and the Disruptor"
order: 21
layout: tutorial
sectionid: docs
part: low-latency-and-high-throughput
description: "Ring buffers revisited as a messaging substrate, the Disruptor pattern, batching and back-pressure, and the single-writer principle that makes it all safe."
duration: "13 min"
---

<!-- PROVENANCE: NEW | anchor books: Son -->

## What we'll cover

- Revisit the ring buffer from a messaging angle: a fixed-size, pre-allocated channel between producer and consumer.
- Introduce the Disruptor pattern: sequence barriers and claim strategies that coordinate multiple consumers over one ring.
- Cover batching as a throughput lever and back-pressure as the mechanism that keeps a fast producer from overrunning a slow consumer.
- Establish the single-writer principle and why it's the property that makes the whole pattern lock-free.

## Ring Buffers Revisited

<!-- TODO: cover the ring buffer as a messaging channel rather than a generic queue -->

## The Disruptor Pattern

<!-- TODO: cover sequence barriers and claim strategies for coordinating multiple consumers -->

## Batching and Back-Pressure

<!-- TODO: cover batching reads for throughput and signaling back-pressure to a producer -->

## The Single-Writer Principle

<!-- TODO: cover why restricting writes to a single owner removes the need for locking -->

## Running in a container

<!-- TODO: container callout — running the Disruptor-pattern example at varying batch sizes inside a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
