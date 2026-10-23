---
title: "Chapter 16: NUMA Placement and Locality on Real Topology"
description: "Against a real 2-NUMA-node KVM guest, this demo checks CPU affinity, numa_alloc_onnode placement, first-touch binding, and the local-vs-remote read gap."
order: 216
card_eyebrow: "Chapter · <strong>16</strong>"
card_title: "NUMA Placement &amp; Locality"
card_blurb: "A disposable two-node KVM guest, not a container, gives this demo a real NUMA topology to be remote across. numa_alloc_onnode placement, first-touch binding, and a cpuset.mems fallback are all checked directly; local-vs-remote latency is reported for context."
layout: example
sectionid: examples
permalink: /examples/16-numa-affinity-and-data-locality/
demo_dir: concurrency/16-numa-affinity-and-data-locality
github_path: examples/concurrency/16-numa-affinity-and-data-locality
---

> The full source for this example lives in [`examples/concurrency/16-numa-affinity-and-data-locality/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/16-numa-affinity-and-data-locality): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 16: NUMA, Affinity, and Data Locality]({{ '/docs/16-numa-affinity-and-data-locality/' | relative_url }})

## What it shows

NUMA behavior cannot be shown truthfully in a container on a single-node host, so this demo runs in a disposable KVM guest provisioned with a real two-node topology instead: the host itself is never touched. `numa_alloc_onnode` placement onto a requested node, first-touch binding of pages to the touching thread's node, and a `cpuset.mems` mismatch forcing a silent fallback to an allowed node are all checked as hard, reproducible assertions on the emulated topology. Local-versus-remote read latency is reported rather than asserted, since the ratio only opens into the chapter's full 1.3–1.6x gap on real multi-socket hardware, not a QEMU-emulated one.

## Running it

```bash
cd examples/concurrency/16-numa-affinity-and-data-locality
./demo.sh            # provision (first run ~2-3 min), build, run, verify
./demo.sh --clean    # destroy the guest and its disks
```
