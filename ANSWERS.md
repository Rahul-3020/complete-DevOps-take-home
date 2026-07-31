# Answers

## Q1 — Migrating ~40 Ingress objects from ingress-nginx to Gateway API, no downtime

**Order of operations:**

- Install the Gateway API CRDs and a Gateway controller (e.g. the same
  nginx-based Gateway fabric, or Envoy Gateway/Istio) alongside the existing
  ingress-nginx — don't touch ingress-nginx yet. Both can run against the
  same Services simultaneously since Gateway API objects are additive.
- Stand up one shared `Gateway` resource (or a couple, split by
  internal/external exposure) mapping to the same listener ports/TLS certs
  ingress-nginx currently serves.
- Migrate Ingress objects to `HTTPRoute` one at a time, starting with the
  lowest-traffic/lowest-risk service. For each: create the HTTPRoute pointing
  at the same backend Service, verify it responds correctly on the *new*
  Gateway's address (via a temporary DNS name or `--resolve`/hosts-file
  testing) before cutting real traffic, then move DNS/weight for that one
  host.
- Where the router supports weighted `backendRefs`, use traffic splitting to
  shift a host gradually rather than flipping all-or-nothing.
- Only once every Ingress has a working, traffic-serving HTTPRoute equivalent
  do I remove the old Ingress objects and eventually decommission
  ingress-nginx.

**What I'd expect to break:**

- Any ingress-nginx-specific annotations (rewrite-target, custom snippets,
  auth-url, rate-limiting annotations) have no 1:1 HTTPRoute equivalent and
  need per-route redesign — this is where most of the real effort goes, not
  the mechanical YAML translation.
- TLS/cert-manager wiring often assumes Ingress-shaped resources; needs
  revalidation against Gateway/Listener certificate refs.
- Client IP preservation / proxy-protocol behavior can differ between
  controllers and is easy to silently regress.
- Some corner-case path-matching semantics (regex vs prefix) differ between
  ingress-nginx and the Gateway API spec and are worth explicitly testing
  per-route, not assumed equivalent.
