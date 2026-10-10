---
title: "Coding Practices for Concurrency"
order: 30
layout: tutorial
sectionid: docs
part: practice
description: "Immutability, RAII locking, const-correctness, minimizing shared state through thread confinement, and the naming and ownership conventions that keep concurrent code reviewable."
duration: "13 min"
---

<!-- PROVENANCE: NEW | anchor books: Williams, Grimm -->

## What we'll cover

- Make immutability the default for any data shared across threads, reducing the surface that needs synchronization at all.
- Reaffirm RAII locking and const-correctness as baseline discipline, not optional polish.
- Cover minimizing shared state through thread confinement, so most data never needs a lock in the first place.
- Establish naming and ownership conventions that make it obvious, from the type alone, which thread or scope owns a piece of state.

## Immutability by Default

<!-- TODO: cover preferring immutable value types for any cross-thread data -->

## RAII Locks and const-Correctness

<!-- TODO: cover baseline discipline for lock usage and const-qualifying read-only access -->

## Minimizing Shared State and Thread Confinement

<!-- TODO: cover confining mutable state to a single thread or task wherever possible -->

## Naming and Ownership Discipline

<!-- TODO: cover naming conventions that signal ownership and thread-affinity at the type level -->

## Running in a container

<!-- TODO: container callout — running the project's lint/static-analysis pass over the example code inside a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
