# parent-pipeline

Central, reusable GitHub Actions pipeline for `cgi-italy` EO processor repos. A child (processor) repo calls one workflow; a clean run builds, scans, and publishes a container image to OTC SWR automatically.

> Internal repository. This repo is maintained by us and documents the shared
> pipeline architecture and its requirements. The processor repos that consume it
> (template: `processor-template`) are the ones shared with external users so they
> can build their own processors. Keep architecture/secret details here.

## The Assembly Line

Every push to `main` in a processor repo runs one folded pipeline. Each stage gates the next: if any scan finds a problem, the pipeline stops and nothing is published.

```
Code arrives (developer pushes to main)
        |
Checkpoint 1 - SECRET SCAN
  TruffleHog scans code/ (filesystem mode) for verified secrets.
  A verified secret STOPS the pipeline.
        |
Checkpoint 2 - BUILD
  Buildx builds code/Dockerfile and pushes a staging image to SWR
  (eopaas-test namespace, tagged with the 8-char commit SHA).
        |
Checkpoint 3 - SECURITY SCAN
  Grype and Trivy scan the staging image (one job, streamed from the
  registry). A HIGH or CRITICAL finding STOPS the pipeline.
        |
Checkpoint 4 - PUBLISH (automatic)
  If every previous checkpoint passed, the scanned staging image is
  copied to the published namespace (eopaas) as :latest.
  No manual approval.
```

Gating is enforced by scanner exit codes plus GitHub `needs:` dependencies. There are no manual approval environments: a clean pipeline publishes on its own, a failing scan blocks publish, unless an authorized maintainer requests a bypass (see below).

## Bypassing the gates

An authorized maintainer can publish an image even when the secret scan and/or the vulnerability scan fail. This exists for exceptional cases (for example an unfixable base-image CVE that must ship while a real fix is prepared). It is deliberately manual and restricted.

### What a bypass does and does not do

- Bypasses Checkpoint 1 (TruffleHog secret scan) and Checkpoint 3 (Grype/Trivy vulnerability scan). One flag covers all three scanners.
- Does NOT bypass the build. Checkpoint 2 must still succeed, so a broken Dockerfile still stops the pipeline.
- Does NOT hide the failure. The scan jobs still run and still fail, so the workflow run is still reported as failed. The `publish` job runs anyway and ships the image.

### How to trigger one

The processor (caller) repo must expose a `bypass_gate` input on its `workflow_dispatch` trigger and forward it to this pipeline (the `processor-template` already does this). To run a bypass:

1. Open the processor repo -> Actions -> the build workflow -> Run workflow.
2. Tick `bypass_gate`, then run it. A bypass only happens on a manual `workflow_dispatch`; a normal `push` never bypasses.

### Who is authorized

The `check_bypass_authorized` job matches `github.actor` (whoever clicked Run workflow) against an explicit allowlist held in `pipeline.yml`:

```yaml
check_bypass_authorized:
  if: ${{ inputs.bypass_gate }}
  ...
  env:
    ALLOWLIST: '["argaar"]'   # edit this list to add/remove maintainers
```

The `cgi-italy` org has no teams, so authorization is this string allowlist rather than a team-membership API call - no extra token or org secret is required. An actor not on the list gets `authorized=false` and `publish` stays blocked. To change who can bypass, edit the `ALLOWLIST` in `pipeline.yml` (changes to this file are the control point, so restrict who can merge them).

### Security consequence

Bypassing Checkpoint 1 means shipping an image built from a commit that contains a verified, live secret. Rotate that credential immediately regardless of the bypass. Bypassing Checkpoint 3 ships known HIGH/CRITICAL vulnerabilities; track the follow-up fix.

## Tools

| Checkpoint | Tool | Job |
|------------|------|-----|
| Secret Scan | TruffleHog (image, filesystem mode) | Fails on verified committed secrets |
| Build | Docker Buildx (`build-push-action`) | Builds and pushes the image, with layer cache |
| Security Scan | Grype (`anchore/scan-action`) | Fails on HIGH/CRITICAL vulnerabilities |
| Security Scan | Trivy (`aquasecurity/trivy-action`) | Fails on HIGH/CRITICAL vulns |
| Publish | Skopeo | Registry-to-registry copy of the scanned image to the published namespace |

## Workflow files

| File | Role |
|------|------|
| `pipeline.yml` | Orchestrator. Chains `scan_secrets -> build_image -> security -> publish` via `needs`. Holds all non-secret config, the `bypass_gate` input, and the `check_bypass_authorized` allowlist |
| `scan_secrets.yml` | TruffleHog filesystem scan of `code/`; blocks on a verified secret |
| `build_image.yml` | Buildx build + push of the staging image; outputs `image_name` |
| `security.yml` | Grype + Trivy scans in one job (registry-streamed, one disk cleanup + cached vuln DBs); block on HIGH/CRITICAL |
| `publish_image.yml` | Skopeo copy of the scanned image to `<prod>/<app>:latest` |

## Requirements to run

### Secrets (4) - set at the `cgi-italy` org level

GitHub reusable workflows resolve `secrets.*` against the CALLER repo and the org, never against parent-pipeline. These 4 secrets are defined once at the `cgi-italy` organization level (Organization Settings -> Secrets and variables -> Actions), with repository access scoped to the processor repos. `secrets: inherit` then passes them into the pipeline for every processor repo with zero per-repo setup.

| Secret | Purpose |
|--------|---------|
| `SWR_USERNAME` | OTC SWR login username. Format `<region>@<AK>`, e.g. `eu-de@AK...`. From a long-term Access Key (AK/SK) |
| `SWR_PASSWORD` | OTC SWR login key derived from the AK/SK pair |
| `BASE_REGISTRY_USERNAME` | Credential to PULL the Dockerfile base image from the internal Harbor (`core.harbor.dev.eoss-cloud.it`) |
| `BASE_REGISTRY_PASSWORD` | Password/robot token for the base image registry pull |

### Non-secret config - lives in `pipeline.yml`

Registry hostnames and namespaces are hardcoded once in `pipeline.yml` and passed to the reusable workflows as `with:` inputs (they are NOT GitHub variables; repo-level vars on parent-pipeline would be invisible to callers). To change them, edit `pipeline.yml` only.

| Input | Value | Meaning |
|-------|-------|---------|
| `swr_registry` | `swr.eu-de.otc.t-systems.com` | OTC SWR registry hostname |
| `swr_staging_org` | `eopaas-test` | SWR namespace for freshly built, not-yet-scanned images |
| `swr_prod_org` | `eopaas` | SWR namespace for published images |
| `base_registry` | `core.harbor.dev.eoss-cloud.it` | Internal registry hosting the Dockerfile base image |
| `bypass_gate` | `false` (default) | Optional boolean input. When `true` on a manual run by an allowlisted actor, publishes despite failing scans. See Bypassing the gates |

### Image naming

```
app name  : repository basename        (cgi-italy/<name> -> <name>)
staging   : swr.eu-de.otc.t-systems.com/eopaas-test/<name>:<sha8>
published : swr.eu-de.otc.t-systems.com/eopaas/<name>:latest
<sha8>    : first 8 characters of the commit SHA
```

## SWR gotchas

- **Namespaces are not auto-created.** The `eopaas-test` (staging) and `eopaas` (published) organizations must already exist in SWR. A missing one fails the push with `Image organization does not exist`.
- **No OCI attestations.** `build_image.yml` sets `provenance: false` and `sbom: false`. Without them Buildx pushes an OCI image index that SWR cannot parse (`Invalid image, fail to parse manifest.json`). Do not remove these unless SWR gains OCI-index support.
- **Base image stays on Harbor.** The Dockerfile `FROM` still pulls from `core.harbor.dev.eoss-cloud.it`, which is why `BASE_REGISTRY_*` credentials are needed even though the output goes to SWR.

## Version pinning and maintenance

- All actions are pinned to exact versions; the skopeo and TruffleHog images are pinned by tag; runners are pinned to `ubuntu-24.04`. No floating refs (`@main`, `:latest`, `ubuntu-latest`).
- `.github/dependabot.yml` opens a monthly grouped PR to bump the pinned actions. The skopeo and TruffleHog image tags are inline `run:` strings, so Dependabot does not track them - bump those by hand.

## Creating a new processor repo

Use `new-repo.sh` (requires the `gh` CLI):

```sh
./new-repo.sh inspect        # read-only: show the template/org config a new repo needs
./new-repo.sh create         # create a new repo from cgi-italy/processor-template
```

A processor repo only needs a `.github/workflows/` that calls this pipeline and its app under `code/` (with a `Dockerfile`). The `processor-template` repo already has both.
