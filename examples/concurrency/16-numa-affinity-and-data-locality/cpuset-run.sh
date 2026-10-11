#!/usr/bin/env bash
# cpuset-run.sh -- run the benchmark confined to a cgroup v2 cpuset whose
# cpuset.mems excludes the node it will ask for, to show numa_alloc_onnode
# silently falling back to an allowed node (the chapter's cpuset-mismatch case).
# Runs as root INSIDE the guest. Usage: cpuset-run.sh <binary> <onnode-N>
#
# This uses a raw cgroup v2 cpuset (not systemd-run) on purpose: it is exactly
# the cpuset.cpus / cpuset.mems mechanism the chapter describes, and it does not
# depend on a D-Bus/systemd transient unit (which is fragile over a
# non-interactive ssh session).
set -euo pipefail
BIN="${1:?need binary path}"
NODE="${2:?need node to request}"
CG=/sys/fs/cgroup/ch16-cpuset

# The cpuset controller must be delegated into child cgroups of the root before
# a child can have cpuset.cpus / cpuset.mems files.
if ! grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
    echo +cpuset > /sys/fs/cgroup/cgroup.subtree_control
fi

mkdir -p "$CG"
echo "0-1" > "$CG/cpuset.cpus"   # allow cores on both nodes...
echo "0"   > "$CG/cpuset.mems"   # ...but memory from node 0 ONLY

# Move this shell into the cgroup; the benchmark inherits the restriction.
echo $$ > "$CG/cgroup.procs"
set +e
"$BIN" --onnode "$NODE"
rc=$?
set -e

# Move back out to the root cgroup so the now-empty cgroup can be removed.
echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
rmdir "$CG" 2>/dev/null || true
exit "$rc"
