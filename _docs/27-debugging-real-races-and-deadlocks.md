---
title: "Debugging Real Races and Deadlocks"
order: 27
layout: tutorial
sectionid: docs
part: correctness-errors-and-debugging
description: "Reproducing an actual data race and an actual deadlock, driving gdb against a multithreaded program, and reading a ThreadSanitizer report line by line."
duration: "15 min"
---

<!-- PROVENANCE: NEW (draws on linux-systems-programming/_docs/28-gdb-and-remote-debugging.md) | anchor books: Son, lsp tooling -->

## What we'll cover

- Construct a real, reproducible data race rather than a hypothetical one, as the worked example for the rest of the chapter.
- Construct a real, reproducible deadlock from a lock-ordering violation.
- Drive gdb against the multithreaded program: inspecting per-thread backtraces, switching threads, and setting thread-scoped breakpoints.
- Read a ThreadSanitizer report for the data race and map each line back to the source locations involved.

## Reproducing a Real Data Race

<!-- TODO: cover constructing a minimal, reliably reproducible data race -->

## Reproducing a Real Deadlock

<!-- TODO: cover constructing a minimal, reliably reproducible lock-ordering deadlock -->

## gdb on Multithreaded Programs

<!-- TODO: cover per-thread backtraces, thread switching, and thread-scoped breakpoints under gdb -->

## Reading a ThreadSanitizer Report

<!-- TODO: cover walking a TSan report for the race example line by line -->

## Running in a container

<!-- TODO: container callout — running the race and deadlock reproduction binaries under gdb inside a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
