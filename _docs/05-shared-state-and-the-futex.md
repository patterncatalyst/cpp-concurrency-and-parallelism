---
title: "Shared State and the Futex"
order: 5
layout: tutorial
sectionid: docs
part: shared-state-and-synchronization
description: "What a mutex actually is underneath the standard library: the futex syscall, and the cost difference between an uncontended and a contended lock."
duration: "14 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/25-shared-state-and-the-futex.md | anchor books: Williams, Tanenbaum -->

## What we'll cover

- Show that a Linux mutex is, underneath, a fast userspace path backed by the futex syscall.
- Explain the futex fast path and slow path, and when the kernel actually gets involved.
- Quantify the cost difference between an uncontended lock acquisition and a contended one that blocks in the kernel.
- Separate what happens in kernel space from what happens in user space during lock acquisition and release.

## What a Lock Is Underneath

<!-- TODO: cover the layered implementation from std::mutex down to the futex syscall -->

## The Futex: Fast Path and Slow Path

<!-- TODO: cover the atomic compare-and-swap fast path and the futex_wait/futex_wake slow path -->

## Uncontended vs Contended Cost

<!-- TODO: cover measured cost differences between uncontended and contended lock acquisition -->

## Kernel Space vs User Space

<!-- TODO: cover which parts of lock acquisition stay in userspace and which cross into the kernel -->

## Running in a container

<!-- TODO: container callout — running the futex-contention example and comparing uncontended vs contended timings in a container -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
