---
title: "Design and Architecture Patterns"
order: 31
layout: tutorial
sectionid: docs
part: practice
description: "Pipeline and SEDA architectures, sharding and the single-writer pattern, half-sync/half-async designs, and how to choose a concurrency architecture for a given service."
duration: "14 min"
---

<!-- PROVENANCE: NEW | anchor books: Grokking Concurrency, Son, Grimm -->

## What we'll cover

- Cover pipeline and SEDA (staged event-driven architecture) designs for decomposing a workload into concurrent stages.
- Cover sharding and the single-writer pattern as a way to parallelize without synchronizing.
- Cover the half-sync/half-async architecture as a bridge between blocking application code and async I/O.
- Give a decision framework for choosing a concurrency architecture based on workload shape and latency targets.

## Pipelines and SEDA

<!-- TODO: cover staged event-driven architecture and pipeline decomposition of a workload -->

## Sharding and the Single-Writer Pattern

<!-- TODO: cover partitioning state by shard with a single writer per shard -->

## Half-Sync/Half-Async

<!-- TODO: cover bridging synchronous application logic with an asynchronous I/O layer -->

## Choosing a Concurrency Architecture

<!-- TODO: cover a decision framework matching workload shape to architecture -->

## Running in a container

<!-- TODO: container callout — running the pipeline/SEDA reference example end to end inside a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
