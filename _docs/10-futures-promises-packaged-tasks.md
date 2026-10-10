---
title: "Futures, Promises, and Packaged Tasks"
order: 10
layout: tutorial
sectionid: docs
part: tasks-futures-async
description: "std::async and its launch policies, the future/promise pair, packaged_task, shared_future, and how exceptions cross the async boundary."
duration: "13 min"
---

<!-- PROVENANCE: NEW (adapted from linux-systems-programming/_docs/51-std-threading.md) | anchor books: Williams ch4, Grimm -->

## What we'll cover

- Cover std::async and its launch policies, including the easy-to-miss default that can silently run synchronously.
- Introduce the future/promise pair as the general building block std::async is built on.
- Cover packaged_task for wrapping a callable with its own future, and shared_future for broadcasting one result to multiple waiters.
- Trace how an exception thrown in the producer surfaces at the consumer's future::get().

## std::async and Launch Policies

<!-- TODO: cover std::launch::async vs std::launch::deferred and the default policy's surprises -->

## future, promise, and packaged_task

<!-- TODO: cover constructing and fulfilling a promise manually, and wrapping a callable with packaged_task -->

## shared_future

<!-- TODO: cover converting a future to a shared_future to support multiple waiters -->

## Exceptions Across the Async Boundary

<!-- TODO: cover how an exception stored in a promise is rethrown at get() -->

## Running in a container

<!-- TODO: container callout — running the packaged_task worker-pool example inside the project's container setup -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
