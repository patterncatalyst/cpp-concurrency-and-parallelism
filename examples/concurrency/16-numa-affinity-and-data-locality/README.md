# 16 — NUMA, Affinity, and Data Locality

Demonstrates, against a real 2-NUMA-node topology, the mechanisms the chapter
teaches: CPU affinity, `numa_alloc_onnode` placement, first-touch binding, the
local-vs-remote read gap, and the silent `numa_alloc_onnode` fallback under a
mismatched `cpuset.mems`.

## Why a VM and not a container

NUMA behavior cannot be shown truthfully in a container on a single-node host:
there is no second node to be remote from. This demo runs in a **disposable KVM
guest** with a 2-node topology instead. **The host is never modified** — no host
NUMA, CPU-governor, or `isolcpus` setting is touched; only the guest's (emulated)
topology is shaped, which is exactly what the chapter's "Running in a container"
section and requirement 5 call for.

On a single-physical-node host, QEMU gives the guest the *topology* (two nodes,
a distance matrix visible to `numactl --hardware`) but not a real remote-memory
*latency* penalty. So:

- **HARD (asserted)** — `numa_alloc_onnode` places pages on the requested node;
  first-touch binds pages to the touching thread's node; a `cpuset.mems`
  mismatch makes `numa_alloc_onnode` silently fall back to an allowed node.
  These are real and reproducible on an emulated topology.
- **SOFT (reported)** — local vs remote read latency. The ratio is ~1.0 here
  and becomes the chapter's 1.3–1.6× gap only on real multi-socket hardware.

## Prerequisites (host)

- `libvirt` + `qemu-kvm` with the `default` NAT network active, and your user in
  the `libvirt` group (see the Prerequisites chapter).
- `virt-install`, `qemu-img`, `cloud-utils` (`cloud-localds`).
- An SSH key at `~/.ssh/id_ed25519.pub`.

No `sudo` is needed to run the demo once libvirt is set up (the `libvirt` group
grants access to `qemu:///system`); the guest itself has passwordless sudo.

## Run

```bash
./demo.sh            # provision (first run ~2-3 min), build, run, verify
./demo.sh --clean    # destroy the guest and its disks
```

The guest (`cpp-conc-numa`) is **reused** across runs — the first run downloads
the Fedora Cloud base image and boots the guest; later runs skip straight to
build + run. Tear it down with `--clean` when finished.

## What you should see

`numactl --hardware` reporting 2 nodes, then:

```
NODES n=2
PLACE requested=0 actual=0
PLACE requested=1 actual=1
FIRSTTOUCH thread_node=0 page_node=0
FIRSTTOUCH thread_node=1 page_node=1
TIMING local_ns=... remote_ns=... ratio=~1.0
ONNODE requested=1 allowed_mems=0 actual=0      # cpuset-confined: silent fallback
RESULT: PASS
```

## Files

| File | Role |
|------|------|
| `src/numa_locality.cpp` | the benchmark (libnuma + `sched_setaffinity`) |
| `CMakeLists.txt` | C++20 build; links `libnuma` |
| `verify.lua` | HARD placement/first-touch/cpuset asserts; SOFT timing report |
| `provision-numa-vm.sh` | provisions the 2-NUMA-node guest (`--destroy` to remove) |
| `cloud-init/` | minimal guest config (toolchain + libnuma + lua) |
| `demo.sh` | provision → build-in-guest → run → verify |
