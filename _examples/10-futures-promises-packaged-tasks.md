---
title: "Chapter 10: Launch Policies and a packaged_task Worker Pool"
description: "std::async's default launch policy is a silent correctness gap, not a guarantee of concurrency: the only way to know whether a task actually ran concurrently is to ask it which thread it ran on."
order: 210
card_eyebrow: "Chapter · <strong>10</strong>"
card_title: "Launch Policies &amp; packaged_task"
card_blurb: "Explicit async and deferred launch policies are checked against the thread id each task actually ran on, not trusted on name alone. A small packaged_task worker pool proves an exception thrown by one task surfaces intact at its own future::get(), leaving every other task unaffected."
layout: example
sectionid: examples
permalink: /examples/10-futures-promises-packaged-tasks/
demo_dir: concurrency/10-futures-promises-packaged-tasks
github_path: examples/concurrency/10-futures-promises-packaged-tasks
---

> The full source for this example lives in [`examples/concurrency/10-futures-promises-packaged-tasks/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/10-futures-promises-packaged-tasks); clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 10: Futures, Promises, and Packaged Tasks]({{ '/docs/10-futures-promises-packaged-tasks/' | relative_url }})

## What it shows

One binary submits identical callables under `std::launch::async`, `std::launch::deferred`, and the default policy, with every callable reporting the thread id it actually executed on: `async` must always land on a thread distinct from the submitter, `deferred` must always run on the submitter's own thread inside `future::get()`, and the default is reported without asserting a direction either way. A second binary is a small fixed-size thread pool built on `std::packaged_task`, where one task throws; that exception is rethrown intact at exactly that task's own `future::get()`, and every other task's result is unaffected. Both halves are checked as hard assertions, since they're standard-mandated guarantees rather than performance claims a busy host could mute.

## Running it

```bash
cd examples/concurrency/10-futures-promises-packaged-tasks
./demo.sh            # build + run launch_policy/worker_pool + verify.lua
./demo.sh --clean    # remove the image
```
