#!/usr/bin/env bash
# concurrency/16-numa-affinity-and-data-locality -- NUMA placement/affinity in
# the KVM lab.
#
# Unlike the Docker-based demos in this series, this one runs in a disposable
# KVM guest with a real 2-NUMA-node topology, because NUMA behavior cannot be
# demonstrated truthfully inside a container on a single-node host (see the
# chapter's "Running in a container" section). THE HOST IS NEVER MODIFIED: host
# NUMA layout, CPU governor, and isolcpus are left untouched; only the guest's
# (emulated) topology is shaped, via provision-numa-vm.sh.
#
# Sequence:
#   1. provision the 2-node guest if it is not already defined
#   2. wait for cloud-init to finish installing the toolchain + libnuma
#   3. copy the source, build it in the guest
#   4. run the benchmark (placement / first-touch / timing)
#   5. run it again confined to cpuset.mems=0 asking for node 1 (fallback case)
#   6. run verify.lua in the guest over both outputs
#
# The guest is REUSED across runs (provision once, ~2-3 min; later runs skip
# straight to build+run). Tear it down with --clean when finished.
#
# Usage:
#   ./demo.sh            provision if needed, build, run, verify
#   ./demo.sh --clean    destroy the guest and its disks
#   DEMO_NO_PAUSE=1 ./demo.sh   skip presenter pauses (CI / scripted)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
VM_NAME="${VM_NAME:-cpp-conc-numa}"
# Dedicated lab key (see provision-numa-vm.sh): IdentityAgent=none +
# IdentitiesOnly force ssh to sign with THIS key file and never consult the
# user's GUI ssh-agent (GNOME keyring / gcr), whose confirmation dialog cannot
# be answered from a non-interactive demo and so hangs every connection.
LAB_KEY="${LAB_KEY:-$HOME/cpp-conc-lab/lab_key}"
# Each guest command below also runs under an explicit `timeout` so a stall
# never blocks the demo indefinitely.
SSH_OPTS="-o IdentityAgent=none -o IdentitiesOnly=yes -i $LAB_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"
REMOTE_DIR="/home/fedora/ch16"

if [[ "${1:-}" == "--clean" ]]; then
    log_step "Destroying the NUMA lab guest"
    ./provision-numa-vm.sh --destroy
    exit 0
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,28p' "$0"; exit 0
fi

require virsh
require ssh
require scp

vm_ip() {
    virsh -q domifaddr "$VM_NAME" 2>/dev/null \
        | awk '/ipv4/ {sub(/\/.*/,"",$4); print $4; exit}'
}

banner "16-numa-affinity-and-data-locality" "NUMA placement + affinity in a 2-node KVM guest"

callout \
    "This runs in a disposable KVM guest with an emulated 2-NUMA-node" \
    "topology. The HOST is never touched. On a single-node host QEMU" \
    "emulates the topology (2 nodes, a distance matrix) but not the remote" \
    "latency, so the timing ratio is ~1.0 here -- the demo HARD-asserts the" \
    "NUMA placement/first-touch/cpuset mechanisms (which are real on an" \
    "emulated topology) and reports timing as SOFT."

# ── 1. provision if needed ────────────────────────────────────────────────
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    log_ok "guest $VM_NAME already defined -- reusing it"
    virsh start "$VM_NAME" >/dev/null 2>&1 || true
else
    log_step "Provisioning the 2-NUMA-node guest (first run: downloads Fedora base, ~2-3 min)"
    ./provision-numa-vm.sh
fi

# ── 2. wait for an IP, then for cloud-init to finish ──────────────────────
log_step "Waiting for the guest to get a DHCP lease"
IP=""
for _ in $(seq 1 60); do
    IP="$(vm_ip)"; [[ -n "$IP" ]] && break
    sleep 3
done
[[ -n "$IP" ]] || { log_err "no DHCP lease for $VM_NAME"; exit 1; }
log_ok "guest IP: $IP"

log_step "Waiting for cloud-init to finish installing the toolchain + libnuma"
ready=0
for _ in $(seq 1 100); do
    if timeout 25 ssh $SSH_OPTS "fedora@$IP" 'grep -q CH16_LAB_READY /var/log/lab-ready 2>/dev/null'; then
        ready=1; break
    fi
    sleep 5
done
[[ "$ready" == "1" ]] || { log_err "cloud-init did not finish in time"; exit 1; }
log_ok "guest toolchain ready"
echo
ssh $SSH_OPTS "fedora@$IP" 'numactl --hardware' || true
echo

pause "About to copy the source and build it in the guest"

# ── 3. copy + build in the guest ──────────────────────────────────────────
log_step "Copying source to the guest and building"
ssh $SSH_OPTS "fedora@$IP" "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
scp $SSH_OPTS -q -r src CMakeLists.txt verify.lua cpuset-run.sh "fedora@$IP:$REMOTE_DIR/"
ssh $SSH_OPTS "fedora@$IP" \
    "cd $REMOTE_DIR && cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null && cmake --build build >/dev/null"
log_ok "built numa_locality in the guest"

pause "About to run the benchmark (placement / first-touch / timing)"

# ── 4. full run ───────────────────────────────────────────────────────────
log_step "Running the NUMA benchmark"
echo
ssh $SSH_OPTS "fedora@$IP" "cd $REMOTE_DIR && ./build/numa_locality | tee full.out"
echo

# ── 5. cpuset-confined run: mems=0, ask for node 1 -> silent fallback ─────
log_step "Running confined to cpuset.mems=0 while asking for node 1 (fallback case)"
echo
timeout 60 ssh $SSH_OPTS "fedora@$IP" \
    "sudo bash $REMOTE_DIR/cpuset-run.sh $REMOTE_DIR/build/numa_locality 1 | tee $REMOTE_DIR/cpuset.out"
echo

pause "About to verify placement (HARD) and report timing (SOFT)"

# ── 6. verify in the guest ────────────────────────────────────────────────
log_step "Running verify.lua in the guest"
set +e
ssh $SSH_OPTS "fedora@$IP" "cd $REMOTE_DIR && lua verify.lua full.out cpuset.out"
rc=$?
set -e

echo
if [[ $rc -eq 0 ]]; then
    log_ok "verify.lua PASSED (exit 0)"
else
    log_err "verify.lua FAILED (exit $rc)"
fi
echo
echo "Guest left running for re-runs. Tear it down with: ./demo.sh --clean"
exit "$rc"
