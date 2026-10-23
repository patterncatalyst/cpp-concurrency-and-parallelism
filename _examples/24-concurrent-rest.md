---
title: "Chapter 24: Back-Pressure and Overload Shedding"
description: "An async server that can accept work faster than it can finish it needs an explicit, cheap rejection path, answered straight from an in-flight counter before a handler ever runs."
order: 224
card_eyebrow: "Chapter · <strong>24</strong>"
card_title: "Back-Pressure &amp; Load Shedding"
card_blurb: "A Boost.Beast async HTTP server enforces an in-flight-request cap with one atomic counter, answering HTTP 503 before a handler ever runs. A two-phase load test proves zero rejections below the cap and clean shedding with no dropped connections above it."
layout: example
sectionid: examples
permalink: /examples/24-concurrent-rest/
demo_dir: concurrency/24-concurrent-rest
github_path: examples/concurrency/24-concurrent-rest
---

> The full source for this example lives in [`examples/concurrency/24-concurrent-rest/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/24-concurrent-rest): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 24: Concurrent REST Endpoints]({{ '/docs/24-concurrent-rest-endpoints/' | relative_url }})

## What it shows

An async HTTP server handles every accepted connection with one coroutine, enforcing a small in-flight-request cap with a single `std::atomic<int>`: pushed over the cap, a request is shed immediately with a 503; under the cap, it's held until the response is written. A load generator built on the same stack drives the server through a warmup phase strictly below the cap (every response must be 200, a hard assertion) and an overload phase well above it (every response must be 200 or 503, with no other error, at least one of each, also hard), proving 503s only appear once the cap is actually exceeded. A final check sends `SIGTERM` and asserts the server drains every in-flight session and exits 0 within a bounded grace period.

## Running it

```bash
cd examples/concurrency/24-concurrent-rest
./demo.sh            # build + run rest_server + rest_client + verify.lua
./demo.sh --clean    # remove the image
```
