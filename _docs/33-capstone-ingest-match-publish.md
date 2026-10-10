---
title: "Capstone: Ingest, Match, Publish"
order: 33
layout: tutorial
sectionid: docs
part: practice
description: "An end-to-end low-latency pipeline (ingest, match, publish) that composes the concurrency, lock-free messaging, and observability patterns from the rest of the book, measured under load."
duration: "24 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/56-capstone-comparison.md + linux-systems-programming/_docs/41-capstone-fleet.md | anchor books: all -->

## What we'll cover

- Compose a single end-to-end pipeline, ingest, match, publish, using one consistent workload so every stage is measured on the same basis.
- Instrument the pipeline to show which concurrency model actually ran each stage, not just which one was configured.
- Instrument the pipeline to show what synchronization between stages actually cost, in both latency and throughput.
- Tie the measured results back to the patterns from earlier parts: thread pools, lock-free queues, mechanical sympathy, and observability.

## The Pipeline: Ingest, Match, Publish

<!-- TODO: cover the three-stage pipeline design and the workload used to drive it -->

## Instrumenting the Pipeline

<!-- TODO: cover instrumentation that reveals which execution model actually ran each stage -->

## Measuring End to End

<!-- TODO: cover end-to-end latency and throughput measurement across all three stages under load -->

## Tying the Book Together

<!-- TODO: cover mapping the measured results back to the concurrency, messaging, and observability chapters that informed the design -->

## Running in a container

<!-- TODO: container callout — running the full ingest-match-publish pipeline, each stage in its own container, under a load generator -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
