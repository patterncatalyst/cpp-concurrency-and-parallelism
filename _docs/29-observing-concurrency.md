---
title: "Observing Concurrency"
order: 29
layout: tutorial
sectionid: docs
part: correctness-errors-and-debugging
description: "Instrumenting a concurrent service with OpenTelemetry, tracing across async boundaries, and the metrics that reveal pool saturation and contention before they become incidents."
duration: "15 min"
---

<!-- PROVENANCE: NEW (draws on linux-systems-programming/_docs/38-opentelemetry-to-lgtm.md) | anchor books: Lim -->

## What we'll cover

- Cover instrumenting a concurrent C++ service with OpenTelemetry's trace, metric, and log signals.
- Cover propagating a trace context across an async boundary (a thread-pool hop, a future, a coroutine suspension) without losing the parent span.
- Define the metrics that matter for concurrency health: pool saturation, lock contention, and queueing latency.
- Wire the signals into the LGTM stack (Loki, Grafana, Tempo, Mimir) for a working observability loop.

## OpenTelemetry for Concurrent Services

<!-- TODO: cover instrumenting a service with traces, metrics, and logs via the OTel C++ SDK -->

## Tracing Across Async Boundaries

<!-- TODO: cover propagating span context across a thread-pool hop, a future, and a coroutine suspension -->

## Metrics for Pool Saturation and Contention

<!-- TODO: cover defining and exporting metrics for thread-pool saturation, lock contention, and queue depth -->

## The LGTM Stack

<!-- TODO: cover wiring the OTel Collector into Loki, Grafana, Tempo, and Mimir for end-to-end visibility -->

## Running in a container

<!-- TODO: container callout — running the instrumented service alongside an LGTM stack in docker compose -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
