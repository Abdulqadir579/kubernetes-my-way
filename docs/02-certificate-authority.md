# Day 2 — The Certificate Authority & TLS

Every component in Kubernetes talks over TLS. The kubelet, the API server,
etcd, the scheduler — none of them trust each other by default. They prove
their identity with a **certificate**, and they only believe a certificate
if it was signed by an authority they trust.

On EKS, AWS *is* that authority. It generates the CA, issues every cert,
mounts them into the control plane, and rotates them — all invisibly. I ran
clusters for years and never saw a single one of these certificates.

Day 2 is where that curtain comes down. We become our own Certificate
Authority and hand-issue every certificate in the cluster.

> 👉 **What EKS did for you:** Managed the entire PKI — issued, mounted, and
> rotated every certificate without you ever seeing one.

---

## The mental model

A Kubernetes cluster is a web of components that only trust each other
through certificates signed by **one** authority. We create that authority
(the CA), then issue an identity to every participant.

```
              [ Our CA ]  ← the root of trust we create
                   |
   signs ----------+-------------------------------------------
   |        |          |            |          |              |
 admin   kubelet   kube-proxy   controller  scheduler   api-server +
        (x2 nodes)              -manager                 service-account
```

Every client cert encodes two things that **are** its identity in Kubernetes:

- **CN (Common Name)** → the Kubernetes **username**
- **O (Organization)** → the Kubernetes **group** (which RBAC binds permissions to)

That CN/O mapping is the single most important idea of the day. There's no
password and no token for these components — the certificate itself says who
you are and what group you're in.

---

## Why run this on the Mac (not the nodes)

All certificate generation happens in **one place** — my Mac — then certs
are distributed to the nodes that need them.

The reason: the CA private key (`ca-key.pem`) is the secret that lets you
sign new, trusted certificates. To sign anything you need that key, so all
signing happens where the key lives. The key never leaves the Mac.

```
   MAC (certs/)                       multipass transfer
   ┌──────────────────┐
   │ ca.pem / ca-key  │──────────────┐
   │ admin.pem        │              ├──→ worker-1: ca.pem, worker-1.pem(+key)
   │ worker-1.pem     │──────────────┤
   │ worker-2.pem     │──────────────┴──→ worker-2: ca.pem, worker-2.pem(+key)
   │ kubernetes.pem   │
   │ ...              │──────────────────→ controller: control-plane certs
   └──────────────────┘
      generate here                   distribute after
```

> 👉 **What EKS did for you:** Both signing *and* placing each cert on the
> right node happened automatically inside AWS via the kubelet TLS bootstrap.
> We split it into two visible steps so you can see what moves where.

---

## Tooling

We use **cfssl** + **cfssljson** (Cloudflare's PKI toolkit) — the same tools
the original "Kubernetes the Hard Way" uses. They're declarative: certs are
described in JSON files that commit cleanly to the repo as reproducible
artifacts.

```bash
brew install cfssl
cfssl version
cfssljson --version
```

- `cfssl` generates certs
- `cfssljson` takes cfssl's JSON output and writes the actual `.pem` files

---

## Step 1 — The CA

Two files define the Certificate Authority.

`ca-config.json` defines **how** certs are signed (validity, allowed uses):

```json
{
  "signing": {
    "default": { "expiry": "8760h" },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
```

The `kubernetes` profile allows both **server auth** (proving a server's
identity, like the API server) and **client auth** (proving a client's
identity, like the kubelet) — most Kubernetes components are both.

`ca-csr.json` describes the CA's own identity:

```json
{
  "CN": "Kubernetes",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [
    { "C": "AE", "L": "Dubai", "O": "Kubernetes", "OU": "CA", "ST": "Dubai" }
  ]
}
```

Generate the CA:

```bash
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
```

This produces:

- `ca.pem` 🟢 — the CA certificate (distributed to every node)
- `ca-key.pem` 🔴 — the CA private key (stays on the Mac, **never committed**)

Verify it's self-signed (Issuer == Subject):

```bash
openssl x509 -in ca.pem -text -noout | head -15
```

A self-signed root shows the **same** Issuer and Subject — it vouches for
itself. Every other cert in the cluster will carry `Issuer: CN=Kubernetes`.

> 👉 **What EKS did for you:** This CA — the root of trust for the whole
> cluster — was generated and locked inside AWS. You never held `ca-key.pem`.

---

## Step 2 — The admin client certificate

This is the certificate behind `kubectl` admin access.

```json
{
  "CN": "admin",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [
    { "C": "AE", "L": "Dubai", "O": "system:masters",
      "OU": "Kubernetes The Hard Way", "ST": "Dubai" }
  ]
}
```

- `CN: admin` → the username
- `O: system:masters` → a built-in group bound to a ClusterRole that can do
  **everything**

Sign it with the CA:

```bash
cfssl gencert \
  -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin
```

Verify the identity baked in:

```bash
openssl x509 -in admin.pem -noout -subject -issuer
# subject= ... O=system:masters, CN=admin
# issuer=  ... CN=Kubernetes
```

> 👉 **What EKS did for you:** `aws eks update-kubeconfig` wired your kubectl
> access to IAM, mapped to Kubernetes groups via the `aws-auth` ConfigMap.
> You never saw a client cert — AWS used IAM tokens instead. Here your raw
> identity *is* this `admin.pem`, and `system:masters` is the same powerful
> group `aws-auth` mapped your IAM role to.

---

## Step 3 — Kubelet certificates (one per worker)

The kubelet's certificate must follow an exact format that Kubernetes'
**Node Authorizer** recognizes:

- `CN: system:node:<nodename>` → the `system:node:` prefix marks it a node
- `O: system:nodes` → the built-in group for all nodes

The kubelet also **serves** (the API server connects to it for
`kubectl logs`/`exec`), so these certs need SANs — the node's name and IP —
injected with `-hostname`:

```bash
cfssl gencert \
  -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -hostname=worker-1,192.168.252.3 \
  -profile=kubernetes \
  worker-1-csr.json | cfssljson -bare worker-1
```

(Repeat for `worker-2` with its IP `192.168.252.4`.)

Verify the SANs landed:

```bash
openssl x509 -in worker-1.pem -noout -text | grep -A1 "Subject Alternative"
# DNS:worker-1, IP Address:192.168.252.3
```

> 👉 **What EKS did for you:** This is the kubelet TLS bootstrap. In EKS a
> joining node auto-requests its kubelet cert and the control plane signs it
> — fully automated. You never named a node or set `system:node:`.

---

## Step 4 — Control-plane client certs

`kube-proxy`, `kube-controller-manager`, and `kube-scheduler` are all
**clients** connecting *to* the API server, so they need no SANs. Each has a
`system:`-prefixed CN and an O matching a built-in group that Kubernetes
already has RBAC bindings for:

| Component | CN | O (group) |
|-----------|-----|-----------|
| kube-proxy | `system:kube-proxy` | `system:node-proxier` |
| controller-manager | `system:kube-controller-manager` | `system:kube-controller-manager` |
| scheduler | `system:kube-scheduler` | `system:kube-scheduler` |

```bash
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -profile=kubernetes kube-proxy-csr.json | cfssljson -bare kube-proxy
# ...same for kube-controller-manager and kube-scheduler
```

You're not inventing permissions — you're handing each component the
identity Kubernetes already expects.

> 👉 **What EKS did for you:** Every one of these component certs was
> generated, mounted, and rotated by AWS inside the managed control plane —
> a plane you couldn't even see.

---

## Step 5 — The service-account key pair

This one is **not for TLS**. The API server uses it to cryptographically
**sign the JWT tokens** every pod's ServiceAccount receives. A pod presents
its token; the API server verifies the signature with this key.

```bash
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -profile=kubernetes service-account-csr.json | cfssljson -bare service-account
```

> 👉 **What EKS did for you:** Every time a pod read a token from
> `/var/run/secrets/...`, this key signed it. AWS held it. It's the root of
> pod identity — and you never knew it existed.

---

## Step 6 — The API server certificate (the big one)

This is the **server** cert for the API server, and SANs are critical here.
Every client checks "does the cert match the address I dialed?" — if the
address isn't a SAN, the connection is rejected. So every name and IP the
API server can be reached by must be baked in:

```bash
cfssl gencert \
  -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -hostname=10.32.0.1,192.168.252.2,127.0.0.1,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster.local,controller \
  -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes
```

Each SAN, decoded:

| SAN | Why |
|-----|-----|
| `192.168.252.2` | controller's real IP (where the API server listens) |
| `127.0.0.1` | local access on the controller |
| `10.32.0.1` | the in-cluster Service IP for the API server (first IP of the service CIDR `10.32.0.0/24`) |
| `controller` | the hostname |
| `kubernetes[.default[.svc[.cluster.local]]]` | the DNS names the API server is known by inside the cluster, at every level |

Verify:

```bash
openssl x509 -in kubernetes.pem -noout -text | grep -A1 "Subject Alternative"
```

> 👉 **What EKS did for you:** Your EKS API endpoint
> (`xxxx.gr7.<region>.eks.amazonaws.com`) was a SAN on AWS's version of this
> exact cert — which is why kubectl trusted it. Here you enumerate every
> address yours answers to.

---

## The complete certificate set

| Cert | Role |
|------|------|
| `ca` | root of trust — signs everything below |
| `admin` | kubectl admin access |
| `worker-1`, `worker-2` | kubelet identities (Node Authorizer) |
| `kube-proxy` | proxy identity |
| `kube-controller-manager` | controller-manager identity |
| `kube-scheduler` | scheduler identity |
| `service-account` | signs pod ServiceAccount tokens |
| `kubernetes` | the API server's server cert |

---

## Step 7 — Distribute certs to the nodes

Each node receives **only** the certs it needs — least privilege applies to
certificates too.

Workers get the CA (to verify the chain) and their own kubelet cert:

```bash
multipass transfer ca.pem worker-1-key.pem worker-1.pem worker-1:/home/ubuntu/
multipass transfer ca.pem worker-2-key.pem worker-2.pem worker-2:/home/ubuntu/
```

Controller gets the control-plane set — CA cert **and** key (the
controller-manager signs things), the API server cert, and the
service-account key:

```bash
multipass transfer \
  ca.pem ca-key.pem \
  kubernetes.pem kubernetes-key.pem \
  service-account.pem service-account-key.pem \
  controller:/home/ubuntu/
```

What each node does **not** get is the point: workers never receive
`ca-key.pem` (they verify, they don't sign) and never get another node's
cert. That selective distribution *is* the security model.

Verify:

```bash
multipass exec worker-1   -- ls -l /home/ubuntu/*.pem   # 3 files
multipass exec controller -- ls -l /home/ubuntu/*.pem   # 6 files
```

> 👉 **What EKS did for you:** Which cert lands on which node, with what
> permissions — AWS did all of it internally. You configured none of it.

---

## Committing safely

Commit the cfssl **configs** (reproducible) but **never** the private keys.
The `.gitignore` rules guard against accidents:

```
certs/*-key.pem
certs/*.csr
```

Confirm before committing:

```bash
git check-ignore certs/ca-key.pem      # must print the path = it's ignored
git status                             # confirm NO *-key.pem are staged
git add certs/*.json .gitignore
git commit -m "Day 2: Certificate Authority and TLS certificates"
git push origin main
```

> ⚠️ A leaked CA key means anyone can mint trusted certs for your cluster.
> This gitignore check is the single most important safety step in the
> series.

---

## Gotchas I hit

- **`cfssl` runs from the directory holding `ca.pem` / `ca-config.json`.**
  It reads them by relative path — run from anywhere else and you get
  `could not read configuration file`.
- **Heredocs (`cat > file <<'EOF'`) silently produce empty files if
  interrupted.** A later `unexpected end of JSON input` / `no such file`
  traced back to a CSR that never got written. Always `cat` the file to
  confirm it has content.
- **`zsh: command not found: #`** — pasting blocks with `# comments` makes
  zsh try to run the comment. Harmless; the real commands still ran.
- **The "lacks a hosts field" WARNING is expected for client certs.** Only
  server certs (kubelet, API server) need SANs. admin, kube-proxy,
  controller-manager, scheduler, and service-account warn — correctly.

---

## Next: Day 3 — Kubeconfigs

We have identities (certs). Next we package them into **kubeconfig** files —
the files that tell each component *where* the API server is and *which*
cert to present when talking to it. EKS generated these too, every time you
ran `aws eks update-kubeconfig`.

> 👉 **What EKS did for you:** Generated a ready-to-use kubeconfig on demand.
> Next we build them by hand — one per component.
