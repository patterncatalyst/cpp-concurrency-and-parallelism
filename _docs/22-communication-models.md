---
title: "Communication Models"
order: 22
layout: tutorial
sectionid: docs
part: communications-and-concurrency
description: "Shared memory versus message passing, the concrete IPC mechanisms available on Linux, and a decision guide for picking among them."
duration: "13 min"
---

<!-- PROVENANCE: NEW (recast from linux-systems-programming IPC chapters) | anchor books: Tanenbaum, Grokking Concurrency -->

## What we'll cover

- Contrast shared memory and message passing as the two fundamental communication models between concurrent components.
- Cover sockets, pipes, and FIFOs as concrete message-passing mechanisms on Linux.
- Cover D-Bus and message framing as higher-level communication building blocks.
- Give a decision guide for picking a communication model based on locality, throughput, and coupling requirements.

## Shared Memory vs Message Passing

<!-- TODO: cover the structural difference between the two models and the coupling each implies -->

## Sockets, Pipes, and FIFOs

<!-- TODO: cover the concrete Linux mechanisms and where each one fits -->

## D-Bus and Message Framing

<!-- TODO: cover D-Bus as a message-passing bus and the framing problem for stream-based transports -->

## Choosing a Communication Model

<!-- TODO: cover a short decision table matching requirements to a communication model -->

## Running in a container

<!-- TODO: container callout — running the pipe-based and socket-based IPC examples between two containers -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
