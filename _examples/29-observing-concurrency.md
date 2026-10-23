---
title: "Chapter 29: Instrumented Thread Pool and the LGTM Stack"
description: "Thread-safety and correct propagation are different guarantees: an instrumented thread pool proves both against a real Grafana LGTM observability backend."
order: 229
card_eyebrow: "Chapter · <strong>29</strong>"
card_title: "Tracing Across a Thread Pool"
card_blurb: "A thread pool captures the submitting request's OpenTelemetry context and hands it to worker threads so pool.task spans nest correctly under their request.handle root. A docker compose stack with Tempo and Mimir backs every assertion with a real trace and metric query."
layout: example
sectionid: examples
permalink: /examples/29-observing-concurrency/
demo_dir: concurrency/29-observing-concurrency
github_path: examples/concurrency/29-observing-concurrency
---

> The full source for this example lives in [`examples/concurrency/29-observing-concurrency/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/29-observing-concurrency): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 29: Observing Concurrency]({{ '/docs/29-observing-concurrency/' | relative_url }})

## What it shows

A ch15-style thread pool is extended with a trace per request: each task captures the submitting thread's active OpenTelemetry context (which still includes the request's root span) and hands it across the pool's thread hop as an explicit parent, instead of relying on the SDK's own thread-safety (which says nothing about propagation). A queue-depth up/down counter makes saturation observable directly rather than inferred from latency. This is the project's first multi-container demo: a `docker compose` stack brings up the instrumented service alongside `grafana/otel-lgtm`, and the verifier queries Tempo and Mimir's own HTTP APIs directly (asserting a discovered trace has exactly one root span and the right number of correctly parented child spans, and that a queue-depth metric actually reached the backend) rather than trusting the service's own exit code.

## Running it

```bash
cd examples/concurrency/29-observing-concurrency
./demo.sh            # build + bring up the stack + run the workload + verify
./demo.sh --clean    # tear down and remove the images this demo built
```
