---
title: "Coroutines in Depth"
order: 11
layout: tutorial
sectionid: docs
part: tasks-futures-async
description: "C++20 coroutine machinery, promise_type and awaitables, the heap allocation that the compiler may elide, and a look ahead to C++26 senders and receivers."
duration: "16 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/53-coroutines.md + linux-systems-programming/_docs/27-async-runtimes-and-coroutines.md | anchor books: Williams, Grimm, Lim -->

## What we'll cover

- Walk the compiler-generated coroutine machinery: the coroutine frame, promise_type, and the awaitable interface.
- Cover HALO (Heap Allocation eLision Optimization) and why the coroutine frame allocation it targets is not guaranteed.
- Cover C++23's std::generator as a standard synchronous coroutine type.
- Identify the lifetime trap where a coroutine captures a reference that doesn't outlive the first suspension point.
- Preview C++26's std::execution senders and receivers as the direction async composition is heading.

## Coroutine Machinery: promise_type and Awaitables

<!-- TODO: cover the coroutine frame, promise_type customization points, and the await_ready/await_suspend/await_resume triad -->

## HALO: The Allocation That May Not Happen

<!-- TODO: cover why coroutine-frame heap elision is permitted but not guaranteed by any particular compiler -->

## The Lifetime Trap

<!-- TODO: cover a reference captured by a coroutine that dangles across a suspension point -->

## C++26 std::execution: Senders and Receivers

<!-- TODO: cover senders/receivers as the next standardized async-composition model -->

## Running in a container

<!-- TODO: container callout — running the coroutine allocation-elision example and checking generated code under different optimization levels in a container build -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
