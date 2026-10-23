---
title: "Prerequisites"
order: 0
layout: tutorial
sectionid: docs
part: orientation
description: "The reference platform (Fedora), the C++ toolchain and container engine to install, the optional KVM lab for the parallelism chapters, and the preferred editor."
duration: "10 min"
---

<!-- PROVENANCE: NEW | Fedora-focused setup chapter | anchor books: none (platform/toolchain reference) -->

## What we'll cover

- The reference platform this book is written and verified against: Fedora Linux.
- The C++ toolchain to install in one step (clang, gcc, CMake, Ninja, gdb, Conan), and why the examples pin the versions they do.
- The container engine the runnable examples use, and how it relates to the chapters' container callouts.
- The optional KVM lab the parallelism and NUMA chapters run in, so a reader never has to change host kernel or NUMA settings.
- The editor assumption: any CMake-aware editor works, with JetBrains CLion as the preferred one.

Every chapter that follows assumes the tools below are already in place. Setting them up once here keeps each chapter focused on concurrency rather than on installation. None of this is exotic: a current Fedora workstation reaches a working state with a single package install plus a container engine.

## The reference platform: Fedora

This book is written and verified on **Fedora Linux** (a current release, Fedora 40 or later). Fedora is the reference host for three concrete reasons that matter to the material. It ships a **current glibc** (2.36 or newer), which changes how `std::thread::hardware_concurrency()` reports CPUs under a container cpuset, a distinction [Concurrency in Containers]({{ '/docs/32-concurrency-in-containers/' | relative_url }}) depends on. It mounts **cgroup v2** by default, so the `cpu.max` quota and `cpu.stat`'s `throttled_usec` field the container chapters read are present without remounting anything. And its toolchain packages track upstream closely, so the recent-standard features this book uses are available from the distribution rather than a from-source build.

Nothing here is Fedora-only in principle: the examples build inside Red Hat UBI 10 containers, which are RHEL-family and install the same packages through `microdnf`, but the host commands in this chapter are written for Fedora's `dnf`. On a Debian or Ubuntu host the package names differ (`apt install clang gdb cmake ninja-build`), and the container builds are unaffected because they run in UBI regardless of the host distribution.

## The C++ toolchain

One `dnf` command installs the compilers, build tools, debugger, and dynamic-analysis tools the examples use:

```bash
sudo dnf install -y \
    clang gcc gcc-c++ \
    cmake ninja-build \
    gdb valgrind \
    lua python3-pip git
```

The book's examples are written in **C++20** and show C++23 and C++26 deltas in tabbed code blocks. The pinned baseline is **clang 18 with libc++** and **gdb 14 or later**; [Build and Toolchain]({{ '/docs/34-appendix-build-and-toolchain/' | relative_url }}) explains why that pairing, and both the appendix and the individual chapters call out any feature that needs a newer toolchain than the baseline ships. A newer Fedora release carries newer compilers, which is fine: the examples build on any clang 18-or-later and GCC 14-or-later. `lua` runs each example's `verify.lua` harness, and `valgrind` backs the Helgrind and DRD passes in [Sanitizers and Dynamic Analysis]({{ '/docs/28-sanitizers-and-dynamic-analysis/' | relative_url }}).

<!-- DIAGRAM SPEC: cream #fdfbf7 background, titled "The prerequisite stack". A tall "Fedora host" band (blue #4a73b8 outline) containing, top to bottom: a green #5a8870 box "C++ toolchain: clang / gcc / cmake / ninja / gdb / valgrind / lua"; a green box "Conan 2 (pip): pins fmt, Boost, gRPC, opentelemetry-cpp per example"; a blue box "Docker engine + compose v2: runs every example in a container"; and an orange #a06030 side box "KVM lab (libvirt + qemu): optional, only for the NUMA / parallelism chapters so host kernel settings are never touched". To the right, a small box "Editor: any CMake-aware; CLion preferred" with an arrow into the toolchain band. A downward arrow from the host band to a terminal box (ink/dark) "./demo.sh -> builds image -> runs -> verify.lua asserts the observable effect". -->
{% include excalidraw.html name="00-prerequisite-stack" caption="Figure 0.1: the prerequisite stack, a Fedora host, the C++ toolchain and Conan, a container engine, an optional KVM lab for the parallelism chapters, and the editor of your choice" %}

## Conan for third-party dependencies

A handful of examples pull in third-party libraries: `fmt` for formatting, Boost for the Asio and Fiber chapters, gRPC for the gRPC service, and opentelemetry-cpp for the observability chapter. The book resolves all of them through **Conan 2**, so no library has to be installed system-wide and every example pins the exact versions it was verified against. Install Conan with pip and detect a default profile once:

```bash
pip install --user "conan~=2.0"
conan profile detect
```

Each example carries its own `conanfile` and builds its dependencies inside the container, so a dependency version in one chapter never collides with another. You do not need to run `conan install` by hand; each example's `demo.sh` does it inside the build.

## The container engine

Every runnable example builds and runs inside a container, and each chapter's "Running in a container" section describes behavior you can reproduce with the engine installed here. The examples target **Docker Engine** with the Compose v2 plugin:

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
```

Run `docker run hello-world` to confirm the daemon is up. The examples use Docker directly (`docker build`, `docker run`, and for the observability chapter `docker compose`); they do not require a Kubernetes cluster. A container CPU limit set with `--cpus` or `--cpuset-cpus` is exactly how the container chapters demonstrate cgroup quota versus cpuset behavior, so the engine is also part of the teaching surface, not only the build system.

## The parallelism lab (optional)

The parallelism and locality chapters measure real multi-core and NUMA behavior. Running those measurements directly on your workstation would mean changing host NUMA, CPU-governor, or isolation settings, changes that affect every other process on the machine. To avoid that, [NUMA, Affinity, and Data Locality]({{ '/docs/16-numa-affinity-and-data-locality/' | relative_url }}) runs in a disposable KVM guest with a synthetic multi-node topology, so the only kernel you ever reconfigure is the guest's. The lab needs libvirt and a few supporting tools:

```bash
sudo dnf install -y virt-install libvirt qemu-kvm cloud-utils
sudo systemctl enable --now libvirtd
sudo virsh net-autostart default && sudo virsh net-start default
```

This is optional: it is required only for the NUMA chapter. The parallel-algorithm and SIMD examples run under plain Docker with a CPU limit and never touch host settings, so most of the book needs only the toolchain and the container engine. The lab tooling and its safety rationale come from the systems-programming companion work, which the parallelism chapters reference directly.

## The editor

The examples are plain CMake projects, so any editor opens them without project-specific setup. The presets emit a `compile_commands.json`, which a clangd-based language server reads to give completion and diagnostics that match the real build. The **preferred editor for this book is JetBrains CLion**, which opens a `CMakeLists.txt` as a project, reads the CMake presets as selectable build configurations, resolves dependencies through the Conan toolchain file, and drives gdb and the sanitizers through its run configurations. Nothing requires it: the examples build, run, and debug identically from the shell, so the only real assumption is that you can open and edit a CMake project in whatever editor you prefer. [Build and Toolchain]({{ '/docs/34-appendix-build-and-toolchain/' | relative_url }}) covers the editor and preset integration in more detail.

## Running an example

Every chapter that ships a runnable example keeps it under `examples/concurrency/NN-slug/`, with a uniform shape: a `demo.sh` that builds the image, runs it, and reports pass or fail. From a clone of the book's repository:

```bash
cd examples/concurrency/09-lock-free-data-structures
./demo.sh
```

`demo.sh` builds the container, runs the program, and then runs that example's `verify.lua`, which asserts the observable effect the chapter claims (the correct final count, the race actually reproduced, the back-pressure actually engaged) and exits non-zero if the claim does not hold. A passing run ends with a clear verified line; `./demo.sh --clean` removes the image afterward.

## Running in a container

These prerequisites install the engine, not a long-running stack: each example is self-contained and tears itself down. The one exception is [Observing Concurrency]({{ '/docs/29-observing-concurrency/' | relative_url }}), which brings up a small `docker compose` stack (an instrumented service plus a Grafana LGTM backend) and shuts it down when the demo finishes. Nothing you install here stays resident between examples.

## Standards: C++20 / C++23 / C++26

The prerequisites are a property of the platform, not of a language standard: the same Fedora toolchain builds the C++20, C++23, and C++26 variants each later chapter shows. The one thing to know up front is that C++26 features (`std::execution` senders, `std::simd`, `std::hazard_pointer`) have no shipping compiler implementation at the time of writing; the chapters that discuss them label them as such and never make the runnable example depend on them. Everything you install here builds the C++20 and C++23 code the examples actually run.

## What we learned

- The reference platform is Fedora, chosen for a current glibc, cgroup v2 by default, and an up-to-date toolchain; the examples themselves build in UBI 10 containers, so the host distribution only affects the setup commands, not the builds.
- One `dnf` install provides the whole C++ toolchain (clang, gcc, CMake, Ninja, gdb, valgrind, lua); Conan 2 pins every third-party library per example so nothing is installed system-wide.
- Docker Engine with Compose v2 runs every example, and a container CPU limit is also how the container chapters demonstrate cgroup quota and cpuset behavior.
- The KVM lab is optional and needed only for the NUMA chapter; it keeps real NUMA experiments inside a disposable guest so host kernel settings are never changed.
- Any CMake-aware editor works; CLion is the preferred one. Each example runs through a single `./demo.sh` whose `verify.lua` asserts the chapter's claim.
