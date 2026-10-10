---
title: "Coordination Primitives"
order: 7
layout: tutorial
sectionid: docs
part: shared-state-and-synchronization
description: "condition_variable, C++20's latch and barrier, and counting_semaphore, and how to choose among them."
duration: "12 min"
---

<!-- PROVENANCE: NEW | anchor books: Grimm, Williams -->

## What we'll cover

- Cover condition_variable correctly, including the predicate-loop idiom that avoids spurious-wakeup bugs.
- Introduce C++20's std::latch for a single-use countdown and std::barrier for a reusable phased rendezvous.
- Introduce std::counting_semaphore for bounding concurrent access without full mutual exclusion.
- Give a decision guide for which primitive fits a given coordination pattern.

## condition_variable and Spurious Wakeups

<!-- TODO: cover the wait-with-predicate idiom and why a bare wait() is a bug -->

## C++20 latch and barrier

<!-- TODO: cover single-use countdown with latch and reusable phased synchronization with barrier -->

## counting_semaphore

<!-- TODO: cover bounding concurrent access with counting_semaphore, contrasted with a mutex -->

## Choosing the Right Primitive

<!-- TODO: cover a short decision table mapping coordination patterns to primitives -->

## Running in a container

<!-- TODO: container callout — running the barrier-phased worker example across a fixed number of container CPUs -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
