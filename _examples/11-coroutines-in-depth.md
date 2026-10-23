---
title: "Chapter 11: Generators, Tasks, and HALO"
description: "Hand-rolled generator and task coroutine types, plus an allocation-counting probe, show what a C++20 coroutine frame actually costs and when the compiler can elide it."
order: 211
card_eyebrow: "Chapter · <strong>11</strong>"
card_title: "Coroutines and HALO"
card_blurb: "A co_yield-based generator and a co_await-able task type using symmetric transfer are both hand-rolled, since C++20 has no standard coroutine type. Allocation-counting probes compare a stateless coroutine against one carrying a live 4 KiB buffer across a suspension point."
layout: example
sectionid: examples
permalink: /examples/11-coroutines-in-depth/
demo_dir: concurrency/11-coroutines-in-depth
github_path: examples/concurrency/11-coroutines-in-depth
---

> The full source for this example lives in [`examples/concurrency/11-coroutines-in-depth/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/11-coroutines-in-depth): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 11: Coroutines in Depth]({{ '/docs/11-coroutines-in-depth/' | relative_url }})

## What it shows

Since C++20 ships coroutines as a language feature with no standard-library coroutine type, this example hand-rolls a `co_yield`-based generator (consumed and then destroyed mid-suspension, well-defined behavior) and a `co_await`-able task type whose final suspension performs symmetric transfer instead of a nested `.resume()` call. A third piece overloads a coroutine promise's allocation operators to count frame allocations for a coroutine with no live state across a suspension point versus one carrying a 4 KiB buffer across a real `co_await`, demonstrating the heap-allocation-elision optimization (HALO) the standard permits but never requires. Generator output and the task's chained result are checked as hard assertions; the allocation counts are reported, not asserted, since HALO elision is toolchain-dependent.

## Running it

```bash
cd examples/concurrency/11-coroutines-in-depth
./demo.sh            # build + run coroutines_in_depth + verify.lua
./demo.sh --clean    # remove the image
```
