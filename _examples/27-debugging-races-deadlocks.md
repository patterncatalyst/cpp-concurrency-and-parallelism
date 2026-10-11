---
title: "Chapter 27 — A Real Data Race and a Real AB/BA Deadlock"
description: "Two deliberately broken programs, each made to fail every run rather than occasionally, debugged with ThreadSanitizer and a live gdb attach."
order: 227
card_eyebrow: "Chapter · <strong>27</strong>"
card_title: "Real Races, Caught Live"
card_blurb: "A racy, unsynchronized counter is proven broken by a ThreadSanitizer build, independent of what any single plain run happens to print. A latch-forced AB/BA deadlock is attached to live with gdb to read the lock cycle directly off both threads' backtraces."
layout: example
sectionid: examples
permalink: /examples/27-debugging-races-deadlocks/
demo_dir: concurrency/27-debugging-races-deadlocks
github_path: examples/concurrency/27-debugging-races-deadlocks
---

> The full source for this example lives in [`examples/concurrency/27-debugging-races-deadlocks/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/27-debugging-races-deadlocks) — clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 27 — Debugging Real Races and Deadlocks]({{ '/docs/27-debugging-real-races-and-deadlocks/' | relative_url }})

## What it shows

`racy_counter` has two threads increment a shared, non-atomic `int` with no synchronization; the program's own printed total can look correct or corrupted from run to run, so it's ThreadSanitizer's report — not any single run's output — that proves the defect. `ab_ba_deadlock` forces two threads into a textbook AB/BA deadlock on every run using a `std::latch`, and a backgrounded instance gets `gdb -p <pid>` attached live, reading the lock cycle straight off both threads' real backtraces rather than inferring it from source. The deadlock build never resolving on its own, and the fixed `scoped_lock` build always completing, are hard assertions; TSan's and gdb's reports are hard whenever the environment lets the respective tool run, and a documented soft skip otherwise.

## Running it

```bash
cd examples/concurrency/27-debugging-races-deadlocks
./demo.sh            # build + run (TSan + gdb checks) + verify.lua
./demo.sh --clean    # remove the image
```
