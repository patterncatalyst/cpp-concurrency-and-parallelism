---
title: "Error Handling vs Exception Handling"
order: 26
layout: tutorial
sectionid: docs
part: correctness-errors-and-debugging
description: "Error codes versus exceptions, std::expected as a middle ground, propagating errors across thread, future, and coroutine boundaries, and exception safety under concurrency."
duration: "14 min"
---

<!-- PROVENANCE: NEW | anchor books: Williams, Lim -->

## What we'll cover

- Contrast error codes and exceptions as the two traditional C++ error-reporting mechanisms, with their respective costs.
- Introduce std::expected<T, E> as a value-based alternative that avoids exception-handling overhead on the hot path.
- Cover how an error or exception propagates across a thread boundary, a future, and a coroutine, and where each one can get lost.
- Cover noexcept and exception safety specifically under concurrency, where a thrown destructor or an unhandled exception in a worker thread has outsized consequences.

## Error Codes vs Exceptions

<!-- TODO: cover the cost and ergonomics trade-off between error codes and exceptions -->

## std::expected

<!-- TODO: cover std::expected<T, E> as a value-based error channel -->

## Propagating Errors Across Thread, Future, and Coroutine Boundaries

<!-- TODO: cover how an exception stored in a future or thrown inside a detached thread is (or isn't) observed by the caller -->

## noexcept and Exception Safety Under Concurrency

<!-- TODO: cover why an uncaught exception on a worker thread terminates the process and how to guard against it -->

## Running in a container

<!-- TODO: container callout — running the error-propagation example across a thread-pool boundary inside a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
