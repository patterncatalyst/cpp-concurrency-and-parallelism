---
title: "Chapter 34 — The Build Harness, Against Its Own Reference Program"
description: "A reference slice of the book's full build-and-verification toolchain — gcc always, clang and ThreadSanitizer best-effort — run against one small shared-counter program."
order: 234
card_eyebrow: "Chapter · <strong>34</strong>"
card_title: "Build Harness Reference Slice"
card_blurb: "A tiny shared-counter program is built with gcc (always) and clang plus ThreadSanitizer (best-effort) to check gcc-vs-clang output parity and confirm a deliberately injected race is flagged only under the TSan build. conan.lock pins the exact declared dependency end to end."
layout: example
sectionid: examples
permalink: /examples/34-appendix-build-and-toolchain/
demo_dir: concurrency/34-appendix-build-and-toolchain
github_path: examples/concurrency/34-appendix-build-and-toolchain
---

> The full source for this example lives in [`examples/concurrency/34-appendix-build-and-toolchain/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/concurrency/34-appendix-build-and-toolchain) — clone the repo, `cd` in, and `./demo.sh`.

Chapter reference: [Doc 34 — Appendix: Build and Toolchain]({{ '/docs/34-appendix-build-and-toolchain/' | relative_url }})

## What it shows

Four threads increment a shared counter two ways — race-free via `std::atomic::fetch_add`, and racily via a plain, unsynchronized read-modify-write behind an opt-in flag — built with gcc unconditionally and with clang plus a ThreadSanitizer leg on a best-effort basis, since clang isn't part of this book's established container toolchain. The gcc build's exact expected count on the safe path, and the injected-race path simply running to completion without crashing, are hard assertions; gcc-versus-clang byte-identical output and the race being flagged only in the TSan build are checked whenever those legs actually built, and reported as a clearly labeled soft skip otherwise, so the container build never fails just because a given host lacks clang or a working sanitizer runtime. A `conan.lock` generated at image-build time is checked against `conanfile.txt`'s declared `fmt` version, demonstrating the lockfile workflow end to end.

## Running it

```bash
cd examples/concurrency/34-appendix-build-and-toolchain
./demo.sh              # build + run all available legs + verify.lua
./demo.sh --clean      # remove the image
```
