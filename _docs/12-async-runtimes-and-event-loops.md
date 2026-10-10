---
title: "Async Runtimes and Event Loops"
order: 12
layout: tutorial
sectionid: docs
part: tasks-futures-async
description: "The epoll event loop underneath async I/O, Boost.Asio's strand and work-guard, and the question of which thread actually runs a given handler."
duration: "14 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/27-async-runtimes-and-coroutines.md + linux-systems-programming/_docs/55-boost-asio.md | anchor books: Williams, Lim -->

## What we'll cover

- Cover the epoll-based event loop that underlies most async I/O runtimes on Linux.
- Introduce Boost.Asio's strand as a serialization mechanism that is not a mutex and does not block.
- Cover the work guard that keeps an io_context's run() call from returning when there's no outstanding work yet.
- Trace, concretely, which thread ends up running a given handler under a multi-threaded io_context.

## The epoll Event Loop

<!-- TODO: cover how epoll_wait underlies an async runtime's readiness notification -->

## Strands and the Work Guard

<!-- TODO: cover Boost.Asio's strand for ordered execution without locking, and the work guard that keeps run() alive -->

## Execution Schedulers

<!-- TODO: cover the general shape of an execution scheduler abstraction over a thread pool -->

## Who Actually Runs Your Handler

<!-- TODO: cover tracing handler execution across io_context threads in a multi-threaded run -->

## Running in a container

<!-- TODO: container callout — running the Boost.Asio echo-server example with a multi-threaded io_context inside a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
