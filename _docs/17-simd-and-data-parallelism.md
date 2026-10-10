---
title: "SIMD and Data Parallelism"
order: 17
layout: tutorial
sectionid: docs
part: parallelism-and-throughput
description: "Vectorization fundamentals, the upcoming C++26 std::simd, data layout choices that enable it, and autovectorization versus hand-written intrinsics."
duration: "14 min"
---

<!-- PROVENANCE: NEW | anchor books: Lim, Brandt -->

## What we'll cover

- Cover the basics of SIMD vectorization: processing multiple data elements with a single instruction.
- Introduce C++26's std::simd as the standardized, portable vector type.
- Cover data layout choices (array-of-structs versus struct-of-arrays) that determine whether vectorization is even possible.
- Compare relying on the compiler's autovectorizer against writing intrinsics or std::simd code directly.

## Vectorization Basics

<!-- TODO: cover what SIMD vectorization does at the instruction level with a minimal example -->

## C++26 std::simd

<!-- TODO: cover the std::simd API shape and how it portably targets different vector widths -->

## Data Layout for SIMD

<!-- TODO: cover array-of-structs versus struct-of-arrays and which one vectorizes -->

## Autovectorization vs Intrinsics

<!-- TODO: cover when to trust the compiler's autovectorizer and when to reach for intrinsics or std::simd explicitly -->

## Running in a container

<!-- TODO: container callout — running the SIMD benchmark across different compiler autovectorization settings in a container build -->
<!-- TODO: VM-lab note — runs in the KVM lab via lgtm-systems-programming; never mutate host NUMA/governor -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
