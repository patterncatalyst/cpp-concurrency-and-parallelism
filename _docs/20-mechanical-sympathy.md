---
title: "Mechanical Sympathy"
order: 20
layout: tutorial
sectionid: docs
part: low-latency-and-high-throughput
description: "False sharing, alignas and hardware_destructive_interference_size, struct layout, and the cache-line discipline that keeps hot data from fighting over a line."
duration: "13 min"
---

<!-- PROVENANCE: NEW | anchor books: Son, Lim -->

## What we'll cover

- Demonstrate false sharing: two unrelated atomics on the same cache line silently serializing two threads.
- Cover alignas and std::hardware_destructive_interference_size as the standard tools for cache-line padding.
- Cover struct layout choices that determine whether hot fields end up on the same or different cache lines.
- Establish a cache-line discipline for designing shared data structures under contention.

## False Sharing

<!-- TODO: cover a minimal false-sharing example and its measured throughput cost -->

## alignas and hardware_destructive_interference_size

<!-- TODO: cover using the standard interference-size constant to pad shared structures -->

## Struct Layout for Cache Lines

<!-- TODO: cover reordering and padding fields to separate independently-written data -->

## Cache-Line Discipline in Practice

<!-- TODO: cover a short checklist for designing a shared structure that avoids false sharing -->

## Running in a container

<!-- TODO: container callout — running the false-sharing benchmark with and without padding inside a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
