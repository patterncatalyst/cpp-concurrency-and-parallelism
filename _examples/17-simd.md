---
title: "Chapter 17: Scalar vs. std::experimental::simd, AoS vs. SoA"
description: "SIMD parallelizes across data inside one thread, and data layout decides whether vectorization is even available before a compiler flag or vector type enters the picture."
order: 217
card_eyebrow: "Chapter · <strong>17</strong>"
card_title: "AoS vs. SoA &amp; SIMD"
card_blurb: "The identical particle-update arithmetic runs scalar over an array-of-structs layout, scalar over a struct-of-arrays layout, and vectorized over struct-of-arrays with std::experimental::simd. All three must hash to bit-identical final positions."
layout: example
sectionid: examples
permalink: /examples/17-simd/
demo_dir: concurrency/17-simd
github_path: examples/concurrency/17-simd
---

> The full source for this example lives in [`examples/concurrency/17-simd/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/17-simd): clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 17: SIMD and Data Parallelism]({{ '/docs/17-simd-and-data-parallelism/' | relative_url }})

## What it shows

One fixed particle dataset gets the identical `pos += vel * dt` recurrence applied three ways: array-of-structs with a scalar loop (strided, defeats vectorization outright), struct-of-arrays with a scalar loop (contiguous, still no explicit vector type), and struct-of-arrays with explicit `std::experimental::simd`: libstdc++'s production-usable portable vector type today, not the unshipped C++26 `std::simd`. Built without `-march=native`, the three variants perform the exact same sequence of multiply-then-add operations batched differently, so their final positions are checked for a bit-identical hash rather than a floating-point tolerance; any mismatch is a hard failure regardless of layout or vectorization. `soa_simd` beating `soa_scalar` is reported as a soft signal, since the margin depends on the build's actual vector width.

## Running it

```bash
cd examples/concurrency/17-simd
./demo.sh            # build + run simd_particles + verify.lua
./demo.sh --clean    # remove the image
```
