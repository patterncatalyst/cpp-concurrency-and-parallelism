---
title: "Codetabs smoke test"
description: "Verifies that the codetabs include renders and that the C++20/23/26 tabs switch. Not part of the book; a later phase deletes this page."
order: 0
layout: tutorial
sectionid: docs
part: orientation
---

<!-- SMOKE TEST — delete in Phase 1 -->

# Codetabs smoke test

This page exists only to prove the `codetabs` include renders three
switchable tabs and that Rouge still highlights each fenced block. A
later phase deletes this file.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
#include <concepts>

template <std::integral T>
T twice(T value) {
    return value + value;
}
```

```cpp
// C++23
#include <print>

int main() {
    std::print("hello from C++23\n");
}
```

```cpp
// C++26
#include <thread>

void run(std::thread::id id) {
    // placeholder for a C++26 feature once standardized tooling lands
    (void)id;
}
```
