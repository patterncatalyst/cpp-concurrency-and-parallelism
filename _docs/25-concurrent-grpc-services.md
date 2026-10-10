---
title: "Concurrent gRPC Services"
order: 25
layout: tutorial
sectionid: docs
part: communications-and-concurrency
description: "The async gRPC completion-queue API, streaming RPCs, and the thread-pool sizing decisions that determine how many requests a gRPC server can serve concurrently."
duration: "14 min"
---

<!-- PROVENANCE: NEW (adapted from cpp-statelessness/_docs/10-grpc-microservices.md) | anchor books: Son -->

## What we'll cover

- Cover gRPC C++'s async completion-queue API as the concurrency model underneath both the sync and callback APIs.
- Walk how a completion queue delivers events and how a server dispatches them to handler code.
- Cover streaming RPCs (client, server, and bidirectional) and how they change the concurrency shape of a handler.
- Cover sizing the server's thread pool against the completion-queue count and the expected concurrent-RPC load.

## The Async gRPC API

<!-- TODO: cover the completion-queue-based async API and how it differs from the callback API -->

## Completion Queues

<!-- TODO: cover how events are enqueued and dequeued, and the tag-based dispatch pattern -->

## Streaming RPCs

<!-- TODO: cover client-streaming, server-streaming, and bidirectional-streaming concurrency shapes -->

## Server Thread-Pool Sizing

<!-- TODO: cover sizing the gRPC server's pool relative to completion-queue count and concurrent-RPC targets -->

## Running in a container

<!-- TODO: container callout — running the streaming gRPC example between two containers and observing thread-pool saturation under load -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
