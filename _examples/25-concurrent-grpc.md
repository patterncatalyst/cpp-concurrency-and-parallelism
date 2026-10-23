---
title: "Chapter 25: Async gRPC Server, Bounded Admission"
description: "A grpc::CompletionQueue is the one concurrency model underneath all of gRPC C++'s APIs, and a server built directly on it needs its own explicit admission control."
order: 225
card_eyebrow: "Chapter · <strong>25</strong>"
card_title: "Bounded gRPC Admission"
card_blurb: "A raw CompletionQueue server implements the CallData state-machine pattern with an explicit admission cap, rejecting overflow calls with RESOURCE_EXHAUSTED instead of streaming anything. Concurrent streaming clients prove the cap holds exactly and the server drains cleanly on SIGTERM."
layout: example
sectionid: examples
permalink: /examples/25-concurrent-grpc/
demo_dir: concurrency/25-concurrent-grpc
github_path: examples/concurrency/25-concurrent-grpc
---

> The full source for this example lives in [`examples/concurrency/25-concurrent-grpc/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/25-concurrent-grpc): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 25: Concurrent gRPC Services]({{ '/docs/25-concurrent-grpc-services/' | relative_url }})

## What it shows

Every call is implemented directly against `grpc::ServerCompletionQueue` as the chapter's `CallData` state machine (`CREATE -> PROCESS -> (WRITE <-> DELAY)* -> FINISH`), re-arming itself at each phase so the server never stops accepting new calls. A single process-wide atomic counter enforces a hard admission cap via a reserve-then-rollback pattern: a call that would push the count over the cap finishes immediately with `RESOURCE_EXHAUSTED`, the gRPC equivalent of an HTTP 503. Concurrent streaming clients, released from the same starting line, prove that exactly `cap` calls succeed at the cap and that overflow calls are rejected with no hang and no third status; a final check confirms the server's per-queue drain loop lets it exit 0 within 10 seconds of `SIGTERM`.

## Running it

```bash
cd examples/concurrency/25-concurrent-grpc
./demo.sh            # build + run server+client inside the container + verify.lua
./demo.sh --clean    # remove the image
```
