---
title: "Sanitizers and Dynamic Analysis"
order: 28
layout: tutorial
sectionid: docs
part: correctness-errors-and-debugging
description: "ThreadSanitizer and AddressSanitizer, Valgrind's Helgrind and DRD, what each tool catches and misses, and wiring them into CI."
duration: "14 min"
---

<!-- PROVENANCE: NEW (draws on linux-systems-programming/_docs/29-valgrind-sanitizers-miri.md) | anchor books: Son, lsp toolbox -->

## What we'll cover

- Cover ThreadSanitizer's compile-time instrumentation approach to detecting data races.
- Cover AddressSanitizer's approach to memory errors and where it overlaps with and differs from TSan.
- Cover Valgrind's Helgrind and DRD as binary-instrumentation alternatives, with their own trade-offs.
- Give a clear picture of what each tool catches, what it misses, and the runtime cost of running it.
- Wire at least one sanitizer into a CI job that fails the build on a detected issue.

## ThreadSanitizer

<!-- TODO: cover building with -fsanitize=thread and interpreting a basic report -->

## AddressSanitizer

<!-- TODO: cover building with -fsanitize=address and the classes of memory error it detects -->

## Valgrind Helgrind and DRD

<!-- TODO: cover running the same race example under Helgrind and DRD and comparing output and runtime cost -->

## CI Integration

<!-- TODO: cover wiring a sanitizer build into a CI pipeline as a required gate -->

## Running in a container

<!-- TODO: container callout — running the same test binary under ASan, TSan, and Valgrind inside a container and comparing results -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
