# Day 1 — Infrastructure: From Managed to Manual

I've run production Kubernetes on **EKS** for years. But EKS handed me the
control plane on a plate — I never stood up the machines, wired them
together, or touched what runs underneath.

So Day 1 starts where every cluster really starts: **raw machines on a
network.** No `eksctl`, no node groups, no managed anything. Three Linux
VMs that don't know they're about to become a Kubernetes cluster.

---

## What we're building

| Node         | Role                    | vCPU | RAM | Why |
|--------------|-------------------------|------|-----|-----|
| `controller` | Control plane           | 2    | 2G  | etcd, API server, scheduler, controller-manager |
| `worker-1`   | Worker                  | 2    | 2G  | kubelet, kube-proxy, containers |
| `worker-2`   | Worker                  | 2    | 2G  | kubelet, kube-proxy, containers |

> 👉 **What EKS did for you:** In EKS, the entire control plane (etcd +
> API server + scheduler + controller-manager) is the part you *never
> see* — AWS runs it across multiple AZs and bills you ~$0.10/hr for it.
> Here, `controller` **is** that hidden plane. You're about to build the
> thing AWS hides.

---

## Why Multipass (and not EC2)

For this series I'm using **Multipass** — Canonical's tool for spinning up
Ubuntu VMs locally. Reasons:

- **Free.** No AWS bill while you learn and break things.
- **Fast.** Native virtualization on Apple Silicon, VMs up in seconds.
- **Disposable.** `delete` + `launch` to start over after a mistake.

The trade-off vs. EC2: **IPs aren't static.** Multipass assigns them from a
local range (`192.168.x.x`) and they can change if a VM is recreated. We
handle that with an env file instead of hardcoding.

> 👉 **What EKS did for you:** Static networking, ENIs, and a VPC you
> didn't design. Here, the network is whatever Multipass gives us — so we
> stay disciplined about referring to nodes by name, not IP.

---

## Prerequisites

- macOS (Apple Silicon or Intel)
- [Multipass](https://multipass.run/) installed
- ~6 GB free RAM, ~30 GB disk

Verify:

```bash
multipass version
```

---

## Step 1 — Launch the three nodes

```bash
multipass launch 24.04 --name controller --cpus 2 --memory 2G --disk 10G
multipass launch 24.04 --name worker-1   --cpus 2 --memory 2G --disk 10G
multipass launch 24.04 --name worker-2   --cpus 2 --memory 2G --disk 10G
```

> Tight on RAM (8 GB Mac)? Drop workers to `--memory 1.5G`.

## Step 2 — Confirm they're running

```bash
multipass list
```

```
Name         State     IPv4             Image
controller   Running   192.168.252.2    Ubuntu 24.04 LTS
worker-1     Running   192.168.252.3    Ubuntu 24.04 LTS
worker-2     Running   192.168.252.4    Ubuntu 24.04 LTS
```

**Record these IPs** — every later step (certs, kubeconfigs, etcd peers)
depends on them.

## Step 3 — Capture your environment

Create `scripts/env.sh` (update IPs to match *your* `multipass list`):

```bash
#!/usr/bin/env bash
export CONTROLLER_IP=192.168.252.2
export WORKER_1_IP=192.168.252.3
export WORKER_2_IP=192.168.252.4

export WORKER_1_POD_CIDR=10.200.1.0/24
export WORKER_2_POD_CIDR=10.200.2.0/24
export SERVICE_CIDR=10.32.0.0/24
export CLUSTER_DNS=10.32.0.10
```

Load it with `source scripts/env.sh`.

## Step 4 — Name resolution between nodes

Give every node a hosts entry so they can find each other by name:

```bash
for node in controller worker-1 worker-2; do
  multipass exec $node -- sudo bash -c 'cat >> /etc/hosts <<EOF
192.168.252.2  controller
192.168.252.3  worker-1
192.168.252.4  worker-2
EOF'
done
```

## Step 5 — Verify the mesh

```bash
multipass exec controller -- ping -c 2 worker-1
multipass exec worker-1   -- ping -c 2 worker-2
```

If each node reaches the others by name, the foundation is ready.

---

## How the networking actually works

Two separate things let the nodes reach each other. Worth understanding,
not just copying.

**(a) They can reach each other at all — shared virtual network.**
When Multipass launches a VM, it attaches it to a virtual switch (a software
bridge) on your Mac. All three VMs plug into that same switch and get IPs
from the same subnet, `192.168.252.0/24`. Because they share one subnet,
traffic between them doesn't need a router — they're "local" to each other,
like three machines on the same physical switch. That's why pinging by **IP**
worked from the very start.

```
        Your Mac
   ┌──────────────────────────┐
   │  Multipass virtual switch │
   │     192.168.252.0/24      │
   │    │       │       │      │
   │ .252.2  .252.3  .252.4    │
   │  ctrl    wk-1    wk-2      │
   └──────────────────────────┘
```

> 👉 **What EKS did for you:** This shared network is what a VPC + subnet
> gives you in AWS. In EKS your nodes talk because AWS placed them in subnets
> inside one VPC and wired the routing. Multipass does the laptop-scale
> version automatically.

**(b) They can reach each other by name — `/etc/hosts`.**
Pinging an IP is direct. Pinging a *name* requires translating that name to
an IP first. There's no DNS server on this little network, so the lookup
fails until each VM has a local cheat-sheet — `/etc/hosts` — mapping names
to IPs. That's what Step 4 sets up.

> 👉 **What EKS did for you:** AWS gives every node a DNS name and runs a
> resolver so names resolve automatically. We have no DNS yet, so `/etc/hosts`
> is the manual stand-in. (Inside the cluster, CoreDNS will later do this for
> pods — a Day 8 topic.)

---

## Gotchas I hit

- `multipass exec <node> -- cmd` runs **inside** the VM; a plain command in
  my terminal runs on **macOS**. I accidentally edited my Mac's `/etc/hosts`
  instead of the VMs' the first time — the giveaway was `broadcasthost` and
  the macOS comment header in the file.
- The `/etc/hosts` heredoc one-liner got mangled by nested quoting. Writing
  each line with a separate `echo` was more reliable.
- Multipass IPs (`192.168.252.x`) are assigned locally and can change if a
  VM is recreated — so I keep them in `scripts/env.sh` rather than
  hardcoding them across the docs.

---

## Where we are

```
[ controller ]      [ worker-1 ]      [ worker-2 ]
 192.168.252.2       192.168.252.3      192.168.252.4
      |                   |                  |
      +-------------------+------------------+
                  flat local network
              (they can all talk by name)
```

Three machines. A flat network. Nothing Kubernetes yet — just like the
moment before AWS provisions your EKS cluster, except *we're* the ones
provisioning.

---

## Next: Day 2 — The Certificate Authority

Everything in Kubernetes talks over TLS. Every component — kubelet, API
server, etcd — proves its identity with a certificate. EKS generates and
rotates all of these silently.

Tomorrow we become our own Certificate Authority and issue every cert by
hand. It's the part most people fear. It's also the part that finally makes
Kubernetes' security model *click*.

> 👉 **What EKS did for you:** Managed the entire PKI — issued, mounted,
> and rotated every certificate without you ever seeing one. We're about
> to do it all manually.
