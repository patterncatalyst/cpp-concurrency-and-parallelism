---
title: "Time, Timers, and Deadlines"
order: 3
layout: tutorial
sectionid: docs
part: foundations
description: "The clock taxonomy a concurrent service actually needs, monotonic time, timeouts, and propagating a deadline across a call chain."
duration: "12 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/24-time-timers-deadlines.md | anchor books: Williams -->

## What we'll cover

- Distinguish steady_clock (monotonic) from system_clock (wall time) and why mixing them up breaks timeout logic.
- Cover the vDSO fast path that lets clock_gettime avoid a syscall, and why that matters for high-frequency time checks.
- Show how to express and enforce a timeout on a blocking or async operation.
- Propagate a single deadline across a chain of nested calls so no individual hop can silently exceed the caller's budget.

## The Clock Taxonomy: steady_clock vs system_clock

<!-- TODO: cover which clock to use for timeouts versus for timestamps, and why -->

## Monotonic Time and the vDSO Fast Path

<!-- TODO: cover how clock_gettime avoids a syscall via the vDSO and what that means for hot-path timing -->

## Expressing and Enforcing Timeouts

<!-- TODO: cover std::chrono-based timeout expressions on blocking and async calls -->

## Propagating Deadlines Across Calls

<!-- TODO: cover carrying a single deadline value through a call chain instead of re-deriving per-hop timeouts -->

## Running in a container

<!-- TODO: container callout — running the timeout and deadline-propagation example under a throttled container CPU quota -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
