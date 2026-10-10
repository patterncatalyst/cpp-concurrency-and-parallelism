---
title: "Mutual Exclusion and Locking"
order: 6
layout: tutorial
sectionid: docs
part: shared-state-and-synchronization
description: "The mutex family, the RAII lock wrapper types, and the lock-ordering discipline that avoids deadlock."
duration: "14 min"
---

<!-- PROVENANCE: NEW (adapted from linux-systems-programming/_docs/50-pthreads.md, 51-std-threading.md) | anchor books: Williams, Grimm -->

## What we'll cover

- Survey the mutex family: mutex, recursive_mutex, timed_mutex, and shared_mutex, and when each is the right choice.
- Cover the RAII lock wrapper types: lock_guard, unique_lock, and C++17's scoped_lock for multi-lock acquisition.
- Establish a lock-ordering convention that prevents circular-wait deadlock across more than one mutex.
- Make the case for RAII locking as the default, with manual lock()/unlock() treated as an exception that needs justification.

## The Mutex Family

<!-- TODO: cover mutex, recursive_mutex, timed_mutex, and shared_mutex and their distinct use cases -->

## RAII Lock Wrappers

<!-- TODO: cover lock_guard, unique_lock, and scoped_lock, including scoped_lock's deadlock-avoiding multi-lock acquisition -->

## Lock Ordering and Deadlock Avoidance

<!-- TODO: cover establishing and enforcing a global lock order, and std::scoped_lock's std::lock-based alternative -->

## RAII Locking Discipline

<!-- TODO: cover why bare lock()/unlock() calls are a code-review flag -->

## Running in a container

<!-- TODO: container callout — running the lock-ordering example and demonstrating a deliberately induced deadlock under gdb -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
