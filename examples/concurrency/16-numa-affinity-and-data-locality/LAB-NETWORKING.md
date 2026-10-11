# Running the ch16 NUMA lab behind a VPN / Docker / GUI ssh-agent

The ch16 example provisions a disposable KVM guest with `qemu:///system` and
builds + runs the NUMA benchmark in it. Three things on a typical corporate
Fedora workstation can break that, none of them a fault in the example. This
note records each symptom, the root cause, and the options.

---

## 1. SSH into the guest hangs forever (GUI ssh-agent)

**Symptom.** `ssh fedora@<guest>` authenticates (`debug1: Server accepts key`)
and then hangs indefinitely; every session, `sftp`, and `scp` hangs the same
way. `virsh`/ping to the guest are fine.

**Cause.** The user's default key (`~/.ssh/id_ed25519`) is held by a **GUI
ssh-agent** — GNOME Keyring / `gcr` (`SSH_AUTH_SOCK=/run/user/<uid>/gcr/ssh`).
When ssh asks the agent to sign, gcr pops a **graphical confirmation / unlock
dialog**. A non-interactive `demo.sh` (or any background/headless ssh) can't
answer it, so the signature never arrives and the connection hangs after the
key is accepted.

**Fix (already applied in this example).** Use a **dedicated, passphrase-less
lab key** and bypass the agent entirely:

```bash
ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i ~/cpp-conc-lab/lab_key ...
```

`provision-numa-vm.sh` generates `~/cpp-conc-lab/lab_key` on first use and
installs its public half in the guest; `demo.sh` passes the options above. No
host change needed. If you run ssh by hand, add those three options or the
agent will hang you again.

---

## 2. The guest has no internet (VPN and/or Docker break NAT)

**Symptom.** The guest boots and gets a `192.168.122.x` lease, can ping the
gateway `192.168.122.1`, but **cannot reach the internet** — `ping 8.8.8.8`
fails and `dnf`/`curl` time out. cloud-init stalls at
`Updating and loading repositories:` and the toolchain never installs.

There are two common, independent causes. Check both.

### 2a. Docker set the FORWARD policy to DROP

Docker inserts firewall rules that set the kernel `FORWARD` chain's default
policy to `DROP`, which silently blocks libvirt guest traffic from being
forwarded out. This is the most likely cause on a workstation that also runs
Docker (every container build in this book does).

Check (root):

```bash
sudo iptables -S FORWARD | head        # look for ": DROP" default policy
```

Fix — allow the libvirt bridge through the FORWARD chain:

```bash
sudo iptables -I FORWARD -i virbr0 -j ACCEPT
sudo iptables -I FORWARD -o virbr0 -j ACCEPT
```

Or, more durably, re-apply libvirt's own rules after Docker has started:

```bash
sudo virsh net-destroy default && sudo virsh net-start default
```

(libvirt reinstalls its NAT/masquerade and FORWARD-accept rules for
`192.168.122.0/24` when the network is (re)started.)

### 2b. A corporate VPN captured the routes / NAT

With a full-tunnel VPN up (e.g. `tun0`/`wt0`), the host's default route goes
into the tunnel and the VPN client often installs firewall/policy-routing rules
that do **not** masquerade the `192.168.122.0/24` guest subnet — so forwarded
guest packets are dropped or sent into the tunnel and discarded. VPN clients
frequently leave these rules in place even after you "disconnect" (watch for a
stale `redhat`/VPN firewalld zone still listing `tun0`).

Options, simplest first:

1. **Provision with the VPN down.** Bring the guest up and let cloud-init
   install the toolchain while disconnected; the guest only needs the internet
   during that one-time install. (If the VPN was recently up, also re-run the
   2a fix — the VPN teardown may have left the FORWARD/NAT rules wrong.)
2. **Exclude the guest subnet from the tunnel.** Configure the VPN for split
   tunneling so `192.168.122.0/24` routes/masquerades out the physical NIC
   instead of the tunnel. (VPN-client specific.)
3. **Masquerade the guest subnet explicitly** out the physical interface:
   ```bash
   sudo firewall-cmd --zone=libvirt --add-masquerade
   sudo firewall-cmd --reload
   ```
   then re-run the 2a fix.

### 2c. Avoid needing guest internet at all (hermetic option)

If host networking can't be changed, skip the in-guest `dnf` entirely: build
`numa_locality` on the host in a Fedora container (the host reaches repos even
when the guest can't), then inject the binary + `libnuma.so.1` into the guest's
disk image with `guestfish` while it is shut off, and have a cloud-init
`runcmd` run the benchmark at boot (runcmd runs as root via systemd — it does
not go through an interactive PAM login session). Read results back offline with
`virt-cat`. This needs no guest internet and no working ssh login, at the cost
of a more elaborate harness. The shipped `demo.sh` uses the simpler ssh path;
this is the fallback for a fully locked-down host.

---

## Quick triage

| Symptom | Cause | Fix |
|---------|-------|-----|
| ssh hangs after "Server accepts key" | GUI ssh-agent (gcr) sign dialog | dedicated lab key + `IdentityAgent=none` (already in scripts) |
| guest pings gw but not internet; `dnf` stalls | Docker `FORWARD` policy DROP | `iptables -I FORWARD -i/-o virbr0 -j ACCEPT`, or restart `default` net |
| same, and a VPN is/was up | VPN didn't NAT the guest subnet | provision VPN-down, split-tunnel the subnet, or add masquerade |
| can't change host networking | — | hermetic: container-build + guestfish-inject + cloud-init runcmd + `virt-cat` |
