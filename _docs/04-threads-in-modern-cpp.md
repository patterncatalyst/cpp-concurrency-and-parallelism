---
title: "Threads in Modern C++"
order: 4
layout: tutorial
sectionid: docs
part: foundations
description: "std::thread and std::jthread, cooperative cancellation with stop_token, and the lifetime and ownership rules that govern joining versus detaching."
duration: "14 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/51-std-threading.md | anchor books: Williams, Grimm -->

## What we'll cover

- Compare std::thread and C++20's std::jthread, including jthread's automatic join on destruction.
- Introduce stop_token and stop_source as the standard cooperative-cancellation mechanism.
- Establish the ownership and lifetime rules a thread object imposes on the caller.
- Contrast joining and detaching, and why detaching is rarely the right default in service code.

## std::thread and std::jthread

<!-- TODO: cover construction, move-only ownership, and jthread's destructor-time join -->

## stop_token and stop_source

<!-- TODO: cover requesting and observing cooperative cancellation across a thread boundary -->

## Thread Lifetime and Ownership

<!-- TODO: cover who owns a thread object and what happens if it outlives or is outlived by its caller -->

## Joining vs Detaching

<!-- TODO: cover the trade-offs of detach() and why join (or jthread's implicit join) is the safer default -->

## Running in a container

<!-- TODO: container callout — running a jthread-based worker example and observing clean shutdown on container stop -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
