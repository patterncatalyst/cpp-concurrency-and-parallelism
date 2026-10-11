#!/usr/bin/env bash
# provision-numa-vm.sh -- provision a disposable Fedora KVM guest with a TWO
# NUMA NODE topology, for the ch16 NUMA/affinity example.
#
# This follows the lgtm-systems-programming lab pattern (cloud-init guest, NAT
# network, overlay disk off a cached base image) so the EXPERIMENT NEVER TOUCHES
# THE HOST: host NUMA layout, CPU governor, and isolcpus are left exactly as
# they are -- the only kernel whose topology we shape is the guest's, via the
# <cpu><numa> cells below.
#
# On a single-physical-node host the guest's two nodes are emulated (QEMU gives
# the guest the TOPOLOGY -- numactl --hardware shows 2 nodes and a distance
# matrix -- but not a real remote-memory latency penalty). That is the expected
# and correct behavior here: the demo verifies NUMA placement/first-touch/cpuset
# mechanisms, which are real on an emulated topology; see verify.lua.
#
# Refuses to clobber an existing domain of the same name; run with --destroy to
# tear it down.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

VM_NAME="${VM_NAME:-cpp-conc-numa}"
VCPUS="${VCPUS:-4}"              # 2 per node
RAM_MB="${RAM_MB:-4096}"        # 2048 per node
CELL_KIB="${CELL_KIB:-2097152}" # 2048 MiB per cell, in KiB; 2 cells == RAM_MB
DISK_GB="${DISK_GB:-20}"
NETWORK="${NETWORK:-default}"
SSH_PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"

FEDORA_VER="${FEDORA_VER:-44}"
BASE_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VER}/Cloud/x86_64/images"
BASE_IMG="${BASE_IMG:-Fedora-Cloud-Base-Generic-${FEDORA_VER}-1.7.x86_64.qcow2}"
# Images live under $HOME (not ~/.cache, which is 0700) in a world-traversable
# dir, because under qemu:///system the hypervisor runs as the 'qemu' user and
# must be able to traverse the path to the disk. $HOME is already o+x; this dir
# is created 0755 below. (libvirt relabels/chowns the disk itself once it can
# reach it.)
CACHE_DIR="${LAB_CACHE:-$HOME/cpp-conc-lab}"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; CYN=$'\033[0;36m'; YLW=$'\033[1;33m'; RST=$'\033[0m'
step() { echo "${CYN}== $*${RST}"; }
ok()   { echo "${GRN}ok $*${RST}"; }
warn() { echo "${YLW}!! $*${RST}"; }
die()  { echo "${RED}xx $*${RST}" >&2; exit 1; }

if [[ "${1:-}" == "--destroy" ]]; then
  step "destroying $VM_NAME"
  virsh destroy "$VM_NAME" 2>/dev/null || true
  virsh undefine "$VM_NAME" --remove-all-storage --nvram 2>/dev/null \
    || virsh undefine "$VM_NAME" 2>/dev/null || true
  rm -f "$CACHE_DIR/${VM_NAME}.qcow2" "$CACHE_DIR/${VM_NAME}-seed.img"
  ok "destroyed $VM_NAME"
  exit 0
fi

command -v virt-install  >/dev/null || die "virt-install not found (sudo dnf install virt-install)"
command -v cloud-localds >/dev/null || die "cloud-localds not found (sudo dnf install cloud-utils)"
command -v qemu-img      >/dev/null || die "qemu-img not found (sudo dnf install qemu-img)"
[[ -f "$SSH_PUBKEY" ]] || die "no SSH public key at $SSH_PUBKEY -- ssh-keygen -t ed25519"
virsh dominfo "$VM_NAME" >/dev/null 2>&1 && \
  die "domain '$VM_NAME' already exists -- run $0 --destroy first"

mkdir -p "$CACHE_DIR"
chmod 755 "$CACHE_DIR"   # qemu (qemu:///system) must be able to traverse this

step "ensuring Fedora ${FEDORA_VER} Cloud Base image is cached"
if [[ ! -f "$CACHE_DIR/$BASE_IMG" ]]; then
  warn "downloading $BASE_IMG (first run only; ~600 MB)"
  curl -fL --retry 3 -o "$CACHE_DIR/$BASE_IMG" "$BASE_URL/$BASE_IMG"
fi
ok "base image: $CACHE_DIR/$BASE_IMG"

step "creating ${DISK_GB}G overlay disk"
OVERLAY="$CACHE_DIR/${VM_NAME}.qcow2"
qemu-img create -f qcow2 -F qcow2 -b "$CACHE_DIR/$BASE_IMG" "$OVERLAY" "${DISK_GB}G" >/dev/null
ok "overlay: $OVERLAY"

step "building cloud-init seed"
PUBKEY_CONTENT="$(cat "$SSH_PUBKEY")"
TMP_USERDATA="$(mktemp)"
sed -e "s|__HOSTNAME__|${VM_NAME}|g" \
    -e "s|__SSH_PUBKEY__|${PUBKEY_CONTENT}|g" \
    "$SCRIPT_DIR/cloud-init/user-data.tmpl" > "$TMP_USERDATA"
SEED="$CACHE_DIR/${VM_NAME}-seed.img"
cloud-localds "$SEED" "$TMP_USERDATA" "$SCRIPT_DIR/cloud-init/meta-data"
rm -f "$TMP_USERDATA"
ok "seed: $SEED"

# The two <numa><cell> entries are what give the guest a real 2-node topology.
# cell0 = vCPUs 0-1 + half the RAM; cell1 = vCPUs 2-3 + the other half.
# Set NUMA_CELLS=0 to provision a plain single-node guest (used for isolating
# whether the NUMA topology itself is at fault).
if [[ "${NUMA_CELLS:-1}" == "0" ]]; then
  CPU_SPEC="host-passthrough"
  step "starting $VM_NAME: ${VCPUS} vCPU / ${RAM_MB}MB (plain, single node)"
else
  CPU_SPEC="host-passthrough,cell0.id=0,cell0.cpus=0-1,cell0.memory=${CELL_KIB},cell1.id=1,cell1.cpus=2-3,cell1.memory=${CELL_KIB}"
  step "starting $VM_NAME: ${VCPUS} vCPU / ${RAM_MB}MB across 2 emulated NUMA nodes"
fi
# virtio-rng feeds the guest entropy from the host; without it a headless cloud
# guest can stall in getrandom() during systemd/PAM session setup, which looks
# exactly like a hung SSH login.
virt-install \
  --name "$VM_NAME" \
  --memory "$RAM_MB" \
  --vcpus "$VCPUS" \
  --cpu "$CPU_SPEC" \
  --rng /dev/urandom \
  --import \
  --disk "path=$OVERLAY,format=qcow2,bus=virtio" \
  --disk "path=$SEED,device=cdrom" \
  --os-variant "${OS_VARIANT:-fedora-unknown}" \
  --network "network=$NETWORK,model=virtio" \
  --graphics none \
  --noautoconsole

ok "domain $VM_NAME created -- wait for cloud-init, then: $SCRIPT_DIR/../../../"
echo "find its IP with the lab's vm-ip.sh (qemu:///system)."
