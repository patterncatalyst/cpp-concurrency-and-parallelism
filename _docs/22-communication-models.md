---
title: "Communication Models"
order: 22
layout: tutorial
sectionid: docs
part: communications-and-concurrency
description: "Shared memory versus message passing, the concrete IPC mechanisms available on Linux, D-Bus as a higher-level bus, and a decision guide for picking among them."
duration: "14 min"
---

<!-- PROVENANCE: NEW (recast from linux-systems-programming IPC chapters) | anchor books: Tanenbaum, Grokking Concurrency -->

## Learning objectives

By the end of this chapter you can:

- Distinguish shared memory from message passing as the two families of inter-process communication, and name the coupling trade-off each makes.
- Choose among pipes, FIFOs, UNIX domain sockets, TCP, and UDP based on locality, ordering, and credential or file-descriptor transfer needs.
- Explain where D-Bus fits as a control-plane message bus rather than a hot-path mechanism.
- Apply length-prefix framing to a stream-based transport that has no built-in message boundaries.
- Identify what changes about each mechanism when the communicating processes run in separate containers.

## Why this matters

Every chapter before this one assumed threads sharing one address space, where the memory model does the work of making a write visible to another reader. Once communication crosses a process or machine boundary, that assumption disappears, and the choice of mechanism becomes a choice about coupling: how much the two sides need to agree on, and how much failure on one side the other side has to tolerate.

Picking the wrong model for a given boundary is a common source of both correctness bugs (an unsynchronized shared-memory read) and operational pain (a control-plane service pushed onto a mechanism meant for a different latency budget). The vocabulary from this chapter determines whether a container's networking or filesystem namespace quietly breaks an otherwise correct design.

## What we'll cover

- Contrast shared memory and message passing as the two fundamental communication models between concurrent components.
- Cover sockets, pipes, and FIFOs as concrete message-passing mechanisms on Linux.
- Cover D-Bus and message framing as higher-level communication building blocks.
- Give a decision guide for picking a communication model based on locality, throughput, and coupling requirements.

Everything so far in this book has assumed threads sharing one address space. This chapter and the next step outside that assumption: communication between separate processes, possibly on separate machines, where the memory model of [Chapter 8]({{ '/docs/08-atomics-and-the-memory-model/' | relative_url }}) no longer reaches and every hand-off has to cross a boundary the kernel, or a network, mediates.

## Shared Memory vs Message Passing

Every inter-process communication mechanism on Linux is one of exactly two families, and the choice between them is a choice about coupling, not just performance. **Shared memory** maps the same physical pages into two or more address spaces, so both sides read and write the same bytes directly: no copy, no kernel involvement on the data path once the mapping exists, but also no delivery guarantee at all. Nothing tells a reader that a writer has changed anything; that notification has to be built separately, typically with futex-and-seqlock machinery ([Chapter 5]({{ '/docs/05-shared-state-and-the-futex/' | relative_url }}) covers the futex): a `futex(2)` word to sleep and wake on, and a seqlock so a reader's optimistic copy of in-flight data can be detected as torn and retried rather than trusted. Shared memory is therefore the tightest possible coupling: both sides must agree on a byte-for-byte layout, must run on the same machine (the mapping is physical pages, not something that crosses a network), and must coordinate their own notification scheme on top.

**Message passing** instead moves discrete, self-contained messages through a kernel-mediated channel (a pipe, a socket, a queue), with the kernel doing the copying and, for most of these channels, the ordering and delivery guarantees as well. The cost is at least one copy (often two: into a kernel buffer, then out again) instead of zero, but the benefit is decoupling: the two sides don't need to agree on memory layout beyond the wire format of the message itself, don't need to run on the same machine, and get built-in back-pressure as part of the channel: a full kernel buffer blocks the writer rather than requiring hand-rolled coordination. The trade is explicit: shared memory buys raw throughput and pays for it in coupling and do-it-yourself synchronization; message passing buys loose coupling, location independence, and built-in flow control, and pays for it in copies.

Most real systems use both, at different layers: shared memory for the tightest, same-host, latency-critical hand-off (the ring buffer channels of [Chapter 21]({{ '/docs/21-lock-free-messaging-and-the-disruptor/' | relative_url }}) are, in the single-process case, a shared-memory pattern applied between threads rather than processes), and message passing for everything that needs to cross a process or machine boundary, tolerate a restart on either side, or does not sit on a latency-critical path.

<!-- DIAGRAM SPEC: Title "Two families of inter-process communication". Two columns on a cream #fdfbf7 background. Left column header "Shared memory" (blue #4a73b8 box): two address-space boxes overlapping a single shared-pages box in the middle, a green #5a8870 "zero-copy data path" arrow between them, and a small orange #a06030 side-note box "notification built separately: futex + seqlock". Label the column "tightest coupling · same host · DIY sync". Right column header "Message passing" (green #5a8870 box): two separate process boxes with a kernel-mediated channel box between them (labeled "pipe / socket / queue"), a red #c0392b "copy" arrow in and out of the kernel box, and a note "ordering + delivery + back-pressure included". Label the column "loose coupling · cross-host · built-in flow control". Below both, a horizontal "mechanism ladder" from tightest/fastest to loosest: shared memory → UNIX socket → pipe/FIFO → TCP/UDP → D-Bus, with throughput decreasing and decoupling increasing left to right. -->
{% include excalidraw.html name="22-communication-families" caption="Figure 22.1: the two IPC families and the mechanism ladder from tightest coupling (shared memory) to loosest (D-Bus)" %}

## Sockets, Pipes, and FIFOs

**Pipes and FIFOs** are the simplest message-passing primitive: a bounded ring of kernel pages (16 pages of 4 KiB each by default, resizable up to a `/proc/sys/fs/pipe-max-size` ceiling with `fcntl(F_SETPIPE_SZ)`) with one read end and one write end. A plain pipe only connects processes that already share a file descriptor, typically parent and child; a FIFO is the same ring given a filesystem name via `mkfifo(3)`, so unrelated processes can rendezvous by path. Both give you byte-stream semantics with one real guarantee worth knowing precisely: a single `write()` of at most `PIPE_BUF` (4096 bytes on Linux) lands atomically, never interleaved with another writer's bytes, but that says nothing about message boundaries, since a `read()` can still return a partial write. A pipe moves bytes; it is not a protocol.

**UNIX domain sockets** cover the same local-machine case with more structure. They come in the same three shapes as network sockets: `SOCK_STREAM` (connected, boundaryless, like TCP), `SOCK_DGRAM` (connectionless, boundary-preserving, but reliable and ordered because delivery never leaves the kernel), and `SOCK_SEQPACKET` (connection-oriented and boundary-preserving, a shape TCP never offers), and they add two abilities no network socket has. `SO_PEERCRED` lets a server ask the kernel, not the client, for the connecting process's verified uid, gid, and pid: this is authentication the client cannot forge, since it never supplies the value. And `SCM_RIGHTS` lets one process hand another an **open file descriptor** across the socket: not a path, not a number, but a live reference to the same open file description, with the same offset and the same status flags, as if `dup(2)`'d into another process. A log consumer that receives a fd this way never opens the file itself; it reads through the fd the producer handed it, which is a fundamentally different trust and lifecycle model than "here's a path, go open it yourself."

**Shared memory with a futex and seqlock**, already introduced above, is the zero-copy end of the spectrum for two processes on the same host: a page mapped via `mmap(2)` (backed by `shm_open` or a plain file), a 32-bit word the kernel's `futex(2)` lets a waiter sleep on and a writer wake, and, for read-mostly data, a seqlock so a reader can copy optimistically and detect, after the fact, whether a writer raced it. The futex matters precisely because it is the *only* real coordination primitive the kernel offers for this: every mutex, condition variable, and semaphore you've used, including the ones underlying `std::mutex`, is userspace protocol built on exactly this one syscall.

**TCP and UDP** are what shared memory and UNIX sockets cannot be: they cross a network. TCP gives a reliable, ordered byte stream with the same boundary-free property as a pipe: a `recv()` can return part of a message or several, so every protocol built on TCP needs its own framing, discussed below. UDP gives connectionless, best-effort, boundary-preserving datagrams: a single `sendto()` becomes one packet, and `recv()` returns it whole or not at all, with no guarantee it arrives or arrives in order. That trade makes UDP the right tool specifically where TCP's guarantees aren't wanted: a discovery beacon that repeats every few hundred milliseconds doesn't need retransmission, because the next beacon is the retransmission, and UDP's multicast mode (`IP_ADD_MEMBERSHIP`, with `IP_MULTICAST_TTL` typically pinned to 1 to keep it link-local) lets one send reach every listener on a group address without the sender enumerating who they are: the mechanism behind peer discovery on a local segment.

## D-Bus and Message Framing

**D-Bus** sits a level above every mechanism so far. It's a message bus: a userspace broker (`dbus-daemon`, or the newer `dbus-broker`), with sd-bus also offering a direct point-to-point connection, that processes connect to over a UNIX socket, publishing well-known bus names, exposing objects with methods and emitting signals other connected processes can subscribe to. Where a raw socket gives you bytes and leaves naming, discovery, and request/response matching entirely up to you, D-Bus gives you all three: a process calls a named method on a named object owned by another named process, gets a correlated reply, and can broadcast a signal to every subscriber without knowing who they are: a publish/subscribe model layered on top of point-to-point sockets. The session bus handles per-user desktop services; the system bus handles system-wide ones (power management, network configuration, hardware hotplug) that unprivileged processes query and privileged daemons answer. The practical reason to know about D-Bus in a Linux systems context, rather than dismiss it as desktop plumbing, is that a large fraction of the system services a long-running process might need to interact with, such as network state, systemd unit control, and UPower battery status, expose no other IPC surface.

D-Bus is not a hot-path mechanism: method calls are marshaled into a self-describing binary format with its own type signatures, routed through (or negotiated with) a broker, and the latency is measured in the hundreds of microseconds to low milliseconds rather than the single-digit microseconds a futex or a pipe achieves. It belongs in a control plane (configuration changes, service discovery, status queries), never in a per-message hot loop. That split, incidentally, is a clean illustration of **message framing**, the problem every stream-based transport eventually has to solve: once you have a byte stream with no message boundaries (TCP, a pipe, a UNIX stream socket), you need a convention for finding where one message ends and the next begins. There are exactly two general approaches. **Length-prefix framing** puts a fixed-size field (commonly a big-endian 16- or 32-bit integer) in front of each message's payload, so a reader always knows up front exactly how many bytes to read before the message is complete: the approach every binary protocol in this book's networking material uses, and the one that scales cleanly to binary payloads that might legitimately contain any byte value, including the delimiter you'd otherwise pick. **Delimiter framing** instead marks the end of a message with a reserved byte sequence (a newline for line-oriented text protocols, D-Bus's own wire format uses explicit lengths internally rather than delimiters) and requires either escaping that sequence inside payloads or restricting what payloads may contain. Length-prefix framing is close to universal in binary protocols for exactly that reason: it needs no escaping, and the reader's job is mechanical. Read the length, then read exactly that many bytes; never scan.

## Choosing a Communication Model

| Requirement | Reach for |
|---|---|
| Same-host, lowest possible latency, tight coupling acceptable | Shared memory + futex/seqlock, or the ring-buffer pattern of Chapter 21 |
| Same-host, decoupled processes, need fd or credential transfer | UNIX domain socket (`SCM_RIGHTS`, `SO_PEERCRED`) |
| Same-host or cross-host, simple byte-stream protocol, reliability matters | TCP with explicit length-prefix framing |
| Local-segment discovery, loss-tolerant, one-to-many | UDP, multicast if the group is unknown in advance |
| Cross-process control plane: configuration, status, system service queries | D-Bus (or an equivalent broker) rather than a hand-rolled socket protocol |
| Already-framed, delimiter-friendly text protocol | Delimiter framing is acceptable; binary payloads should use length-prefix |

The underlying question behind every row is the same: how tightly can the two sides afford to be coupled, and how much of that coupling cost is actually paid back in latency or throughput where it matters. A latency-critical same-host hand-off justifies shared memory's coupling; a control-plane query that runs once a second does not, and reaching for raw shared memory there trades real engineering risk for a performance gain nobody will ever observe.

## Running in a container

UNIX domain sockets and shared memory both assume something containers don't automatically give you: a shared filesystem namespace. A UNIX socket is addressed by a path, and two containers each in their own mount namespace see different filesystems by default: a socket bound inside one container's `/tmp` is absent from another's entirely. The fix is an explicit shared mount: a bind-mounted volume (`-v /host/sockets:/sockets` in both containers, pointed at the same host directory) gives both sides a common path to `bind` and `connect` against. The same requirement applies, more strictly, to POSIX shared memory: `shm_open` names land in `/dev/shm`, which is a `tmpfs` mount private to each container's mount namespace by default, so two containers sharing a ring buffer need either the same bind-mounted `tmpfs`, or to run in the same pod/IPC namespace (Kubernetes' `shareProcessNamespace` and a shared volume, or plain `docker run --ipc=container:<other>` for a direct namespace share). Without one of those, each container's `/dev/shm/ring` is a distinct, unrelated file, and the mapping silently fails to be shared at all rather than failing loudly.

TCP and UDP need none of this ceremony, which is precisely why they're the default choice for anything crossing a container boundary: each container's network namespace already provides addressable sockets to any other container on the same network, with no shared mount or namespace trick required, at the cost of the extra copies and (for TCP) the framing work described above.

## Standards: C++20 / C++23 / C++26

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20: no standard error-union type. A socket read typically returns a
// raw ssize_t and leaves errno to be checked, or is wrapped by hand in a
// project-specific optional/variant pair.
ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
if (n < 0) {
    // caller must separately consult errno
}
```

```cpp
// C++23: std::expected<T, E> (header <expected>) gives a standard
// vocabulary type for a fallible receive, carrying the error alongside
// the success type instead of requiring a side channel like errno.
#include <expected>

std::expected<std::size_t, std::error_code> recv_frame(int fd, std::span<std::byte> buf) {
    ssize_t n = ::recv(fd, buf.data(), buf.size(), 0);
    if (n < 0) {
        return std::unexpected(std::error_code(errno, std::generic_category()));
    }
    return static_cast<std::size_t>(n);
}
```

```cpp
// C++26 (proposed, experimental — no shipping compiler implements
// std::execution yet): an async receive expressed as a sender, composing
// with the rest of an I/O pipeline on a scheduler instead of a blocking
// call on a dedicated thread.
namespace ex = std::execution;

ex::sender auto frame = ex::schedule(io_scheduler)
    | ex::then([fd] { return recv_frame(fd, buffer); });
```

C++20 offers nothing specific to inter-process communication beyond the atomics and `jthread`/`stop_token` machinery already covered in earlier chapters: a socket or pipe read is still a plain syscall wrapped however the project's error-handling convention demands. C++23's `std::expected` is a modest but real improvement for this domain specifically: every mechanism in this chapter is fallible in ordinary operation (a peer closes, a socket errors, a pipe's reader disappears), and representing that with a standard vocabulary type rather than an errno side channel or a project-specific wrapper is a real simplification. C++26's `std::execution` is, as in the previous chapter, a reframing to watch rather than something to build on today: treating a socket receive as a composable sender rather than a blocking call matters most for building large asynchronous I/O pipelines, but the facility remains unimplemented by any shipping compiler, and nothing in this chapter depends on it.

## What we learned

- Shared memory and message passing are the two IPC families: shared memory maps the same pages into multiple address spaces for zero-copy access but leaves notification and layout agreement to be built by hand (the futex-and-seqlock pattern); message passing moves discrete messages through a kernel-mediated channel at the cost of at least one copy, in exchange for decoupling, location independence, and built-in back-pressure.
- Pipes and FIFOs are a kernel ring of pages with byte-stream semantics and only `PIPE_BUF`-sized write atomicity; UNIX domain sockets add structured conversation shapes plus kernel-verified credentials (`SO_PEERCRED`) and open-file-description transfer (`SCM_RIGHTS`); TCP and UDP trade the local machine for the network, with UDP multicast the tool of choice for loss-tolerant, one-to-many discovery.
- D-Bus is a message bus layered over sockets, giving named services, method calls, and signals for a control plane: not a hot-path mechanism, but often the only IPC surface a system service exposes.
- Every stream-based transport needs explicit message framing; length-prefix framing is the default for binary protocols because it needs no escaping and makes a reader's job mechanical: read the length, then read exactly that many bytes.
- The decision between mechanisms is a coupling decision as much as a performance one, and crossing a container boundary changes the calculus: UNIX sockets and shared memory need an explicit shared mount or namespace, while TCP and UDP work across containers by default through ordinary network namespacing.

Next, **the actor model and channels** takes message passing a step further: structuring an entire concurrent system so that no mutable state is ever shared at all, only messages.
