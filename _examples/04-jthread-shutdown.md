---
title: "Chapter 04 — SIGTERM to Clean jthread Shutdown"
description: "A process whose SIGTERM path calls request_stop() on every outstanding jthread and joins them all exits cleanly, well inside an orchestrator's grace period."
order: 204
card_eyebrow: "Chapter · <strong>04</strong>"
card_title: "Clean jthread Shutdown"
card_blurb: "SIGTERM sets a lock-free flag; the main thread then calls request_stop() and join() on every worker itself, since request_stop() isn't signal-safe. A Lua harness sends a real SIGTERM and asserts exit 0 inside the grace period, with no forced kill."
layout: example
sectionid: examples
permalink: /examples/04-jthread-shutdown/
demo_dir: concurrency/04-jthread-shutdown
github_path: examples/concurrency/04-jthread-shutdown
---

> The full source for this example lives in [`examples/concurrency/04-jthread-shutdown/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/04-jthread-shutdown) — clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 4 — Threads in Modern C++]({{ '/docs/04-threads-in-modern-cpp/' | relative_url }})

## What it shows

Several `jthread` workers poll a `stop_token` in a tight loop while a real `SIGTERM` handler is installed before any of them start. Because `std::stop_source::request_stop()` is not guaranteed async-signal-safe, the handler only performs a relaxed atomic store; the main thread polls that flag and performs every `request_stop()`/`join()` call itself — a clean shutdown path without smuggling undefined behavior into a signal handler. The verifier drives the binary as its own child process, sends a `SIGTERM`, and asserts the process exits 0 inside a configurable grace period, escalating to `SIGKILL` (and a hard failure) only if it doesn't.

## Running it

```bash
cd examples/concurrency/04-jthread-shutdown
./demo.sh            # build + run jthread_shutdown + verify.lua
./demo.sh --clean    # remove the image
```
