---
title: "Appendix: Build and Toolchain"
order: 34
layout: tutorial
sectionid: docs
part: Appendix
description: "The project's build and verification toolchain: clang and gdb, CMake presets, Conan lockfiles, the Lua verify.lua harness, and GCC/clang parity checks."
duration: "14 min"
---

<!-- PROVENANCE: NEW (mirrors the cpp-statelessness build appendix) | anchor books: none (build/toolchain reference) -->

## What we'll cover

- Document the clang and gdb toolchain versions this book's examples are built and verified against.
- Document the CMake presets used to configure each example consistently.
- Document the Conan lockfiles that pin third-party dependency versions across the book.
- Document the Lua verify.lua harness that checks an example actually produces its observable effect, and the GCC-versus-clang parity checks that run alongside it.

## Toolchain: clang and gdb

<!-- TODO: cover the pinned clang and gdb versions and how to install them -->

## CMake Presets and Conan Lockfiles

<!-- TODO: cover the CMakePresets.json layout and the Conan lockfile workflow -->

## The Lua verify.lua Harness

<!-- TODO: cover what verify.lua checks and how it's invoked per example -->

## GCC vs clang Parity

<!-- TODO: cover the parity-check process that confirms examples build and behave the same under both compilers -->

## Running in a container

<!-- TODO: container callout — running verify.lua against every example inside the project's container build -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
