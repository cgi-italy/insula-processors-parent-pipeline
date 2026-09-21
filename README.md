# insula-processors-parent-pipeline

Central, reusable GitHub Actions building blocks for Insula EO processors. They
secret-scan, build, security-scan, and publish a processor container image to OTC
SWR. They are called by the orchestrator `build-external.yml` in the
`cgi-italy/insula-processor-launcher` repo, which is triggered by the
`insula-processors-builder` CLI.

> Public repository, but write-locked to maintainers (ruleset + CODEOWNERS).
> External users don't interact with it directly - they use the launcher via the
> CLI. It must be public because a public repo (the launcher) cannot call a
> private repo's reusable workflows.
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
Finalize                     (in the launcher) inject the published image into the CWL, publish it as a
                             GitHub Release tagged "cwl-<correlation_id>" (public download URL).
        |
        v
CLI reads the release asset URL and POSTs { executionUnit: { href } } to
https://insula.earth/ogcapi/processes with the user's api token (locally; the token
never enters Actions). Insula fetches the CWL from that URL.
```

Gating is scanner exit codes plus `needs:` dependencies. No manual approval
environments.

## Bypassing the gates

A maintainer can publish an image despite a failing secret or security scan.
Authorization is by the actor's effective role on the launcher repo (admin or
maintain, team grants included: the `insula-pipeline-maintainers` team qualifies),
checked by the `check_bypass_authorized` job in the launcher's `build-external.yml`
using the plain `GITHUB_TOKEN`. The scans still run and still fail; `publish` runs
anyway only when an authorized actor set the flag. Any other actor setting it has
no effect, so exposing the input is safe.

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
| `build_image.yml` | Buildx build + push of the staging image; outputs `image_name`. Inputs: `repo_slug`/`ref`/`app_name`/`source_path`. Logs in to the base-image registry (pull) + SWR (push) |
| `security.yml` | Grype + Trivy in one job (registry-streamed, cached DBs); block on HIGH/CRITICAL, including UNFIXED vulnerabilities (both scanners count them) |
| `publish_image.yml` | Skopeo copy (retried) to `<prod>/<app>`: immutable `:sha8` first, then `:latest`; staging credential reads the source and cleans up staging, the prod-write credential (only present here) is the copy destination; outputs `published_image` |

Each secret-using job (`build_image`, `security`, `publish_image`) declares
`environment: swr`. That environment, defined on the CALLER (the launcher) with a
deployment-branch rule of default-branch-only, is what stops a user's side-branch
dispatch from reading the registry secrets.

## Requirements to run

### Registry credentials

Registry credentials are provisioned by the pipeline maintainers as environment
secrets in the launcher's `swr` environment, restricted to the launcher's default
branch (reusable workflows resolve `secrets.*` against the caller, and the branch
policy stops a side-branch dispatch from reading them). Two SWR credentials exist
on purpose (least privilege): the job building the untrusted Dockerfile holds only
a staging-scoped credential; the prod-write credential exists only in the publish
job, after both scans passed. Provisioning, scoping, and rotation are documented
internally.

Private base images are not supported: the launcher is public, so no base-image
pull credentials can be passed as inputs. Base images must be public.

### Non-secret config - in the launcher's `build-external.yml`

Registry hostnames and namespaces are passed to the reusable workflows as `with:`
inputs from `build-external.yml`. To change them, edit that file.

| Input | Value | Meaning |
|-------|-------|---------|
| `swr_registry` | `swr.eu-de.otc.t-systems.com` | OTC SWR registry hostname |
| `swr_staging_org` | `eopaas-test` | SWR namespace for freshly built, not-yet-scanned images |
| `swr_prod_org` | `eopaas/eopaas` | SWR namespace for published images (tenant-prefixed) |

### Image naming

```
app name  : <owner>-<name>                 (owner/<name> -> <owner>-<name>)
staging   : swr.eu-de.otc.t-systems.com/eopaas-test/<owner>-<name>:<sha8>
published : swr.eu-de.otc.t-systems.com/eopaas/eopaas/<owner>-<name>:latest  (+ :<sha8>)
<sha8>    : first 8 characters of the built commit (external repo HEAD)
```

The app name is owner-scoped so `owner/foo` and `otheruser/foo` do not collide on
the shared `:latest` tag. It is lowercased (registry repository names must be
lowercase) and validated against `^[a-z0-9][a-z0-9._-]*$` before it reaches a
registry path.

## Version pinning and maintenance

- The launcher consumes these reusable workflows PINNED to a commit SHA of this
  repo (never `@main`): a merge here goes live only when the launcher bumps its 4
  pinned refs together. This repo has no tags/releases yet, so those pins are
  bumped by hand.
- All actions are pinned to a full commit SHA with the version in a trailing
  comment; skopeo and TruffleHog images are pinned by `@sha256:` digest; runners
  pinned to `ubuntu-24.04`. No floating refs or mutable tags.
- `.github/dependabot.yml` opens a monthly grouped PR to bump pinned actions
  (Dependabot updates SHA-pinned actions and keeps the version comment in sync).
  The skopeo/TruffleHog image digests are inline `run:` strings, so bump those by
  hand. Take the skopeo digest from a `*-immutable` quay.io tag only: quay
  garbage-collects untagged manifests, so a digest read off a moving tag dies when
  that tag is rebuilt.
- `actions/create-github-app-token` (used by the launcher's finalize step to mint the
  CWL-publish App token) is pinned; keep it in the launcher repo's dependabot config.

## GITHUB_TOKEN permissions

Every workflow sets least-privilege `permissions`. The reusable workflows default to
`permissions: {}`; the two that check out code (`scan_secrets`, `build_image`)
re-grant only `contents: read`. `security` and `publish_image` need no token access
(registry work uses the SWR secrets; DB caching uses the Actions runtime token). The
launcher's `build-external.yml` sets top-level `permissions: contents: read`. Nothing
in the pipeline needs write from `GITHUB_TOKEN`.

## Onboarding and processor creation

Users self-scaffold from the cookiecutter template
(`cgi-italy-insula-processors/insula-processor-template`) and build/deploy via the
`insula-processors-builder` CLI. Launch access on the launcher repo is granted by
a pipeline maintainer; the onboarding and operations procedures are documented
internally.
