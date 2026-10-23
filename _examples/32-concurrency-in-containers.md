---
title: "Chapter 32: cgroup cpu.max vs. hardware_concurrency()"
description: "std::thread::hardware_concurrency() tracks a cpuset restriction but never a cgroup CPU quota, since a time budget doesn't remove any core from the set a thread could be scheduled onto."
order: 232
card_eyebrow: "Chapter · <strong>32</strong>"
card_title: "cgroup Quota vs. hardware_concurrency()"
card_blurb: "A probe reads cpu.max directly, derives a pool size from the tighter of the real quota and the affinity-visible core count, and runs a small CPU-bound pool-bench sized to that result instead of the host's raw core count."
layout: example
sectionid: examples
permalink: /examples/32-concurrency-in-containers/
demo_dir: concurrency/32-concurrency-in-containers
github_path: examples/concurrency/32-concurrency-in-containers
---

> The full source for this example lives in [`examples/concurrency/32-concurrency-in-containers/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/32-concurrency-in-containers): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 32: Concurrency in Containers]({{ '/docs/32-concurrency-in-containers/' | relative_url }})

## What it shows

`cgroup_probe` reads `/sys/fs/cgroup/cpu.max`, folding every "no usable quota" case into the same empty state with every `/sys` read guarded against a missing or unexpected layout; it reports `hardware_concurrency()` next to the cpuset-visible affinity count, derives a pool size from whichever is tighter, and then actually runs a CPU-bound benchmark sized to that pool rather than just printing numbers. Under a plain, unconstrained `docker run`, `cpu.max` correctly reads "unlimited" and the pool size matches the affinity count: the fallback path every CI run exercises, held to a hard assertion. Running the same image with a real `--cpus` limit shows the quota path diverging from `hardware_concurrency()`, checked as a soft assertion since a default run never supplies a quota at all.

## Running it

```bash
cd examples/concurrency/32-concurrency-in-containers
./demo.sh              # build + run cgroup_probe + verify.lua (fallback path)
./demo.sh --cpus=1     # same, but with a real cgroup quota
./demo.sh --clean      # remove the image
```
