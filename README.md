# Enterprise Bot DevOps Take-Home

## How to run and verify

```bash
./setup.sh
```

This creates (or reuses) a kind cluster named `demo`, installs ingress-nginx
(kind flavour, wired to hostPorts 80/443), builds `demo-service:1.0.0` from
`service/`, loads it into the cluster, and installs `chart/` as Helm release
`demo` in namespace `demo`. It's idempotent — safe to re-run.

Verify:

```bash
kubectl -n demo get pods
kubectl -n demo rollout status deployment/demo

# directly via port-forward
kubectl -n demo port-forward svc/demo 8080:80 &
curl http://localhost:8080/
curl http://localhost:8080/healthz

# via Ingress (host demo.local)
curl --resolve demo.local:80:127.0.0.1 http://demo.local/
```

`GET /` should return `{"app":"demo-service","version":"1.0.0","pod":"<hostname>"}`.

To confirm `APP_NAME`/`VERSION` are read from the ConfigMap (not hardcoded),
e.g.:

```bash
helm upgrade demo ./chart -n demo --reuse-values --set config.appName=renamed
kubectl -n demo rollout restart deployment/demo   # env vars from a ConfigMap
                                                    # don't hot-reload into a
                                                    # running container; a
                                                    # rollout is the correct,
                                                    # standard way to pick up
                                                    # the change
kubectl -n demo rollout status deployment/demo
curl --resolve demo.local:80:127.0.0.1 http://demo.local/
```

For the debug lab (Part 4), see `lab/FINDINGS.md` and `lab/part4-session.log`
(to be added once run against a real cluster — see "What I deliberately
skipped" below).

## Resource requests/limits, and why

Every workload in `chart/values.yaml` defaults to:

```yaml
requests: { cpu: 50m, memory: 64Mi }
limits:   { cpu: 200m, memory: 128Mi }
```

This is a tiny stateless HTTP service with no meaningful compute or working
set — the numbers are deliberately modest so multiple replicas fit comfortably
on a laptop-sized kind cluster:

- **50m/64Mi request** is roughly what an idle Node process needs (V8
  baseline + a handful of open sockets), leaving headroom in scheduling
  decisions without over-reserving cluster capacity.
- **200m/128Mi limit** gives a 4x request:limit burst headroom for a spike
  (e.g. a burst of concurrent requests or GC pauses) without one replica
  being able to starve its node neighbours.
- Memory request == likely steady-state usage (no growing cache/heap here),
  so OOM risk under normal load is low; the limit is there mainly to bound a
  runaway/leak scenario, not because we expect to approach it.

These are placeholder-quality numbers for a synthetic app with no real
traffic profile — see "production-ready" below for what I'd actually do
before trusting them.

## What I deliberately skipped, and the risk

- **Didn't wire real image tags to a registry** — `chart/values.yaml` uses
  `image.repository: demo-service` (a local-only tag loaded via `kind load
  docker-image`). Fine for this exercise; in a real cluster this would need
  a real registry and immutable digests, or `setup.sh` would silently break
  the moment someone runs it against a non-kind cluster.
- **No NetworkPolicies** — every Deployment can talk to every other Service
  in the namespace/cluster by default. Risk: lateral movement if any one
  workload is compromised. Would add default-deny + explicit allow rules
  next.
- **No PodDisruptionBudget / HorizontalPodAutoscaler** — `replicaCount: 2` is
  static. Risk: a voluntary disruption (node drain, cluster upgrade) could
  take both replicas down at once; no autoscaling under real load.
- **No resource/perf testing behind the numbers above** — they're
  reasonable-looking defaults, not numbers backed by a load test. Risk:
  wrong in either direction (throttling under real traffic, or wasted
  reservation) until validated.
- **Ingress has no TLS** — plain HTTP only, since this is a local kind
  cluster. Risk: obviously unacceptable outside a local demo.
- **Part 4 session recording (`lab/part4-session.log`) is not included yet**
  — I don't have Docker/kind/kubectl or general network access in the
  environment I prepared this submission in, so I couldn't actually run
  `./scenario.sh up/verify` myself. `lab/broken-chart/` has fixes for the
  four defects I could confirm from careful manifest review against
  `cluster-state/` (see `lab/FINDINGS.md` for the reasoning on each), but the
  `Symptom` fields, the session recording, and any remaining defect(s) still
  need a real run on a real cluster — which I have not fabricated. This is
  the single biggest gap in this submission and the first thing I'd finish
  given more time.

## What I'd change to make this production-ready

- Real registry + immutable image digests (not floating tags), pushed by CI.
- TLS via cert-manager, NetworkPolicies (default-deny + explicit allows), a
  PodDisruptionBudget, and an HPA tied to actual load-tested thresholds.
- Multi-environment values (`values-staging.yaml`, `values-prod.yaml`) rather
  than one `values.yaml`, and the chart in a proper chart repo / OCI registry
  instead of a local path.
- Structured logging + a ServiceMonitor/metrics endpoint, since right now
  there's no observability beyond `/healthz`.
- The `.github/workflows/ci.yml` bonus workflow (lint + build + Trivy scan)
  wired to actually push the built/scanned image on merge to main, with a
  separate CD step (Argo CD / Flux, or a follow-up Helm deploy job) rather
  than deploying by hand.
- Template `BACKEND_URL`-style cross-service URLs off `.Release.Namespace`
  rather than hardcoding a namespace name anywhere (this is exactly the bug
  behind lab Defect 1 — worth generalizing the fix, not just patching the
  one instance).

## How I used AI

I (the candidate) used Claude (Anthropic) for this submission, roughly as
follows:

- **Scaffolding Parts 1-3** (service code, Dockerfile, Helm chart, `setup.sh`):
  drafted with Claude from the assignment spec, then reviewed line-by-line —
  in particular I checked the multi-stage Dockerfile's non-root user setup,
  the LimitRange-safe resource defaults, and that `setup.sh`'s idempotency
  claim actually holds (guarded `kind get clusters`/`helm upgrade --install`
  checks) rather than trusting it by default.
- **Part 4 (debug lab):** Claude did a static read of `broken-chart/` against
  `cluster-state/` and identified/fixed 4 of the 6 defects (wrong namespace
  in `BACKEND_URL`, `metrics` resources exceeding the LimitRange max, the
  RoleBinding targeting the wrong ServiceAccount, and the Job's invalid
  `restartPolicy: Always`). It did **not** run the lab against a real
  cluster (no Docker/kind/network access in that environment), so it did not
  fabricate command output, a session recording, or the remaining 1-2
  defects — those are marked TODO in `lab/FINDINGS.md` and still need to be
  found and pasted in from a real run on my machine before submission.
- **Part 5 (Gateway API migration question):** drafted with Claude, then
  edited down to my own reasoning/priorities.
- **What I corrected/changed:** [fill in once you've actually run the lab —
  e.g. any additional defect(s) found, adjustments to the fixes above once
  tested against a live cluster, wording changes to FINDINGS.md with real
  output].

I have not yet run this end-to-end on a real cluster myself; that's next.
