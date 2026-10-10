---
title: "Fibers and Stackful Coroutines"
order: 13
layout: tutorial
sectionid: docs
part: tasks-futures-async
description: "Stackful fibers versus stackless coroutines, what the fiber's own stack buys and costs, the guard page, and choosing a scheduler."
duration: "13 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/54-boost-fiber.md | anchor books: Grimm, Son -->

## What we'll cover

- Contrast stackful fibers (their own stack, cooperative scheduling) with stackless coroutines (compiler-managed state machine).
- Quantify what a fiber's dedicated stack buys in programming-model simplicity, and what it costs in memory.
- Cover the guard page that catches a fiber stack overflow before it corrupts adjacent memory.
- Lay out the scheduler choices Boost.Fiber exposes and when the default isn't the right one.

## Stackful vs Stackless

<!-- TODO: cover the practical programming-model difference between fibers and C++20 coroutines -->

## What the Stack Actually Buys

<!-- TODO: cover the memory cost of a fiber stack versus the synchronous-looking code it enables -->

## The Guard Page

<!-- TODO: cover how a guard page detects stack overflow in a fiber -->

## Choosing a Scheduler

<!-- TODO: cover Boost.Fiber's pluggable scheduler and when the round-robin default should change -->

## Running in a container

<!-- TODO: container callout — running the fiber-based worker example and comparing its memory footprint against a thread-based equivalent in a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
