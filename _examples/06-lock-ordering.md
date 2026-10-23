---
title: "Chapter 06: AB/BA Deadlock and the scoped_lock Fix"
description: "Two threads that acquire the same two mutexes in opposite order deadlock with lock_guard, and cannot with scoped_lock."
order: 206
card_eyebrow: "Chapter · <strong>06</strong>"
card_title: "Lock Ordering &amp; Deadlock"
card_blurb: "A std::latch forces two threads into a textbook AB/BA deadlock under lock_guard on every single run. The identical opposite-order acquisition under std::scoped_lock always completes, because its internal algorithm doesn't care what order its own arguments name."
layout: example
sectionid: examples
permalink: /examples/06-lock-ordering/
demo_dir: concurrency/06-lock-ordering
github_path: examples/concurrency/06-lock-ordering
---

> The full source for this example lives in [`examples/concurrency/06-lock-ordering/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/06-lock-ordering); clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 06: Mutual Exclusion and Locking]({{ '/docs/06-mutual-exclusion-and-locking/' | relative_url }})

## What it shows

Two mutexes and two threads acquire them in opposite order under `std::lock_guard`, with a `std::latch` closing the scheduling window so the circular wait happens on every run instead of depending on luck: that mode never exits on its own, and the non-exit is the point. The same opposing-order acquisition repeated under `std::scoped_lock` always completes, because `scoped_lock`'s deadlock-avoidance algorithm is indifferent to argument order. The verifier runs the deadlock build under a `timeout --signal=KILL` and asserts it had to be killed, then runs the fixed build and asserts it always finishes with the correct operation count: both hard assertions, since a latch-forced deadlock has no scheduling noise to make soft.

## Running it

```bash
cd examples/concurrency/06-lock-ordering
./demo.sh            # build + run lock_ordering (both modes) + verify.lua
./demo.sh --clean    # remove the image
```
