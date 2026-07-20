# insula-processors-parent-pipeline

Central, reusable GitHub Actions building blocks for Insula EO processors. They
secret-scan, build, security-scan, and publish a processor container image to OTC
SWR. They are called by the orchestrator `build-external.yml` in the
`cgi-italy/insula-processor-launcher` repo, which is triggered by the
`insula-processors-builder` CLI.

> Internal repository, maintainers only. External users never get access here.
> They keep their processor repo PUBLIC under their own name (scaffolded from the
> `cgi-italy-insula-processors/insula-processor-template` cookiecutter), and launch
> the pipeline through the CLI. This repo documents the shared pipeline and its
> requirements.

## Model (clone / dispatch)

The flow:

```
insula-processors-builder CLI  (user machine, holds the Insula api token)
        |  workflow_dispatch (Actions:write on the launcher only)
        v
insula-processor-launcher / build-external.yml
        |  clones the PUBLIC processor repo, then calls the blocks below
        v
Checkpoint 1 - SECRET SCAN   TruffleHog over the cloned code; verified secret STOPS.
Checkpoint 2 - BUILD         Buildx builds code/Dockerfile; pushes staging image to SWR (eopaas-test, :sha8).
Checkpoint 3 - SECURITY SCAN Grype + Trivy on the staging image; HIGH/CRITICAL STOPS.
Checkpoint 4 - PUBLISH       Skopeo copies the scanned image to eopaas/eopaas:latest (+ :sha8). Automatic.
Finalize                     (in the launcher) inject the published image into the CWL, upload it as artifact "cwl".
        |
        v
CLI downloads the "cwl" artifact and POSTs it to https://insula.earth/ogcapi/processes
with the user's api token (locally; the token never enters Actions).
```

Gating is scanner exit codes plus `needs:` dependencies. No manual approval
environments.

## Bypassing the gates

An allowlisted maintainer can publish an image despite a failing secret or security
scan. The `bypass_gate` input and the `check_bypass_authorized` allowlist live in
the launcher's `build-external.yml` (match on `github.actor`). The scans still run
and still fail; `publish` runs anyway only when an authorized actor set the flag. A
non-allowlisted actor setting it has no effect, so exposing the input is safe.

- Build must still succeed; a bypass skips the scan GATES only.
- The CLI's `--bypass` implies no CWL deploy by default (so a maintainer does not
  deploy under their own api token); `--force-publish` overrides.
- To relaunch a failed build, read its `repo_url`/`ref` from the run (also in the
  run-name) and re-dispatch with `--bypass`.

## Tools

| Checkpoint | Tool | Job |
|------------|------|-----|
| Secret Scan | TruffleHog (image, filesystem mode) | Fails on verified committed secrets |
| Build | Docker Buildx (`build-push-action`) | Builds and pushes the image, with layer cache |
| Security Scan | Grype (`anchore/scan-action`) | Fails on HIGH/CRITICAL vulnerabilities |
| Security Scan | Trivy (`aquasecurity/trivy-action`) | Fails on HIGH/CRITICAL vulns |
| Publish | Skopeo | Registry-to-registry copy of the scanned image to the published namespace |

## Workflow files (reusable building blocks)

The orchestrator (`build-external.yml`) lives in `insula-processor-launcher`, not
here. This repo ships only the reusable jobs it calls:

| File | Role |
|------|------|
| `scan_secrets.yml` | TruffleHog filesystem scan; blocks on a verified secret. Inputs: `repo_slug`, `ref` (checks out the external repo; empty = the caller) |
| `build_image.yml` | Buildx build + push of the staging image; outputs `image_name`. Inputs: `repo_slug`/`ref`/`app_name`/`source_path`. Logs in to Harbor (base image pull) + SWR (push) |
| `security.yml` | Grype + Trivy in one job (registry-streamed, cached DBs); block on HIGH/CRITICAL |
| `publish_image.yml` | Skopeo copy to `<prod>/<app>:latest` (+ `:sha8`); outputs `published_image` |

Each secret-using job (`build_image`, `security`, `publish_image`) declares
`environment: swr`. That environment, defined on the CALLER (the launcher) with a
deployment-branch rule of default-branch-only, is what stops a user's side-branch
dispatch from reading the registry secrets.

## Requirements to run

### Secrets (4) - in the `swr` environment on the launcher repo

Reusable workflows resolve `secrets.*` against the caller repo/org. The caller is
`insula-processor-launcher`, so the 4 secrets live in that repo's `swr`
environment (Settings -> Environments -> swr -> Environment secrets), and the
environment's deployment branches must be restricted to the default branch. They
reach the jobs via `secrets: inherit` only when the run is on that branch.

| Secret | Purpose |
|--------|---------|
| `SWR_USERNAME` | OTC SWR login username. Format `<region>@<AK>`, e.g. `eu-de@AK...` |
| `SWR_PASSWORD` | OTC SWR login key derived from the AK/SK pair |
| `BASE_REGISTRY_USERNAME` | Credential to PULL the Dockerfile base image from the internal Harbor (`core.harbor.dev.eoss-cloud.it`) |
| `BASE_REGISTRY_PASSWORD` | Password/robot token for the base image registry pull |

Store these ONLY as `swr` environment secrets on the launcher (not org-scoped, not
in insula-processors-parent-pipeline). Org or plain repo secrets would be readable by any workflow on
any branch, so a user's side-branch dispatch could dump them; environment secrets
are readable only by the environment-scoped jobs, which the branch policy blocks on
non-default branches.

Private base images are not supported: the launcher is public, so no base-image
pull credentials can be passed as inputs. Base images must be public or on the
internal Harbor (pulled with `BASE_REGISTRY_*` above).

### Non-secret config - in the launcher's `build-external.yml`

Registry hostnames and namespaces are passed to the reusable workflows as `with:`
inputs from `build-external.yml`. To change them, edit that file.

| Input | Value | Meaning |
|-------|-------|---------|
| `swr_registry` | `swr.eu-de.otc.t-systems.com` | OTC SWR registry hostname |
| `swr_staging_org` | `eopaas-test` | SWR namespace for freshly built, not-yet-scanned images |
| `swr_prod_org` | `eopaas/eopaas` | SWR namespace for published images (tenant-prefixed) |
| `base_registry` | `core.harbor.dev.eoss-cloud.it` | Internal registry hosting the Dockerfile base image |

### Image naming

```
app name  : external repo basename        (owner/<name> -> <name>)
staging   : swr.eu-de.otc.t-systems.com/eopaas-test/<name>:<sha8>
published : swr.eu-de.otc.t-systems.com/eopaas/eopaas/<name>:latest  (+ :<sha8>)
<sha8>    : first 8 characters of the built commit (external repo HEAD)
```

## SWR gotchas

- **Namespaces are not auto-created.** `eopaas-test` (staging) and `eopaas/eopaas`
  (published) must already exist in SWR, or the push fails with `Image
  organization does not exist`.
- **No OCI attestations.** `build_image.yml` sets `provenance: false` and
  `sbom: false`; otherwise Buildx pushes an OCI image index that SWR cannot parse.
- **Base image stays on Harbor.** The Dockerfile `FROM` still pulls from
  `core.harbor.dev.eoss-cloud.it`, hence the `BASE_REGISTRY_*` credentials.

## Version pinning and maintenance

- All actions are pinned to exact versions; skopeo and TruffleHog images pinned by
  tag; runners pinned to `ubuntu-24.04`. No floating refs.
- `.github/dependabot.yml` opens a monthly grouped PR to bump pinned actions. The
  skopeo/TruffleHog image tags are inline `run:` strings, so bump those by hand.
- `actions/upload-artifact` (used by the launcher's finalize step) is pinned; keep
  it in the launcher repo's dependabot config.

## Onboarding and processor creation

Users self-scaffold from the cookiecutter template and build via the CLI. To grant
a new joiner launch access, use `insula-processor-launcher/onboard-joiner.sh`
(`verify` / `onboard USER` / `offboard USER`). See that repo's `WORKFLOW.md` for
the end-to-end flow.
