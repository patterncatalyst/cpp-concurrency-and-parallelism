---
title: "Chapter 12 - Strand vs. Mutex: Serialization Without a Lock"
description: "A strand serializes handlers without a mutex: the same unsynchronized counter comes back exact through a strand and measurably wrong posted straight to a multithreaded io_context."
order: 212
card_eyebrow: "Chapter · <strong>12</strong>"
card_title: "Strand vs. Mutex Serialization"
card_blurb: "The identical unsynchronized counter is incremented by several threads through a shared Asio strand and directly on a multithreaded io_context. The strand always lands on the exact count with zero overlaps; posted directly, real overlaps appear."
layout: example
sectionid: examples
permalink: /examples/12-asio-strand/
demo_dir: concurrency/12-asio-strand
github_path: examples/concurrency/12-asio-strand
---

> The full source for this example lives in [`examples/concurrency/12-asio-strand/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/12-asio-strand): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 12: Async Runtimes and Event Loops]({{ '/docs/12-async-runtimes-and-event-loops/' | relative_url }})

## What it shows

N copies of one handler are posted either through a shared `asio::strand` or straight to a multithreaded `io_context`; the handler widens its own race window so the no-strand case's overlap is a deterministic, CI-reliable signal rather than a coin flip on a quiet host. Through the strand, the counter always lands exactly on the expected total with zero observed overlaps: Asio's own serialization guarantee holds regardless of how long a handler occupies its thread; posted directly, real interleaving shows up. A second pair of modes compares the same always-correct work guarded by a strand versus a `std::mutex`, using each thread's own voluntary-context-switch count as a portable proxy for how often work had to cross into the kernel.

## Running it

```bash
cd examples/concurrency/12-asio-strand
./demo.sh            # build + run asio_strand (all four modes) + verify.lua
./demo.sh --clean    # remove the image
```
