# parent-pipeline

Central, reusable GitHub Actions pipeline for `cgi-italy` EO processor repos. Child repos call one workflow; a clean run publishes a container image to OTC SWR automatically.

## The Assembly Line

Every push to `main` in a child repo runs one folded pipeline. Each stage gates the next: if any scan finds a problem, the pipeline stops and nothing is published.

```
Code arrives (developer pushes to main)
        |
Checkpoint 1 - SECRET SCAN
  TruffleHog scans code/ for verified secrets.
  A verified secret STOPS the pipeline.
        |
Checkpoint 2 - BUILD
  Buildx builds code/Dockerfile and pushes a staging
  image to SWR (eopaas-test namespace, tagged with the commit SHA).
        |
Checkpoint 3 - SECURITY SCAN
  Grype and Trivy scan the staging image in parallel.
  A HIGH or CRITICAL finding STOPS the pipeline.
        |
Checkpoint 4 - PUBLISH (automatic)
  If every previous checkpoint passed, the staging image is
  copied to the published namespace (eopaas) as :latest.
  No manual approval.
```

Blocking is enforced by scan exit codes plus GitHub `needs:` dependencies. There are no manual approval gates: a clean pipeline publishes on its own, a failing scan blocks publish.

## Tools Used

| Checkpoint | Tool | Job |
|------------|------|-----|
| Secret Scan | TruffleHog (action) | Fails on verified committed secrets |
| Build | Docker Buildx (`build-push-action`) | Builds and pushes the image, with layer cache |
| Security Scan | Grype (`anchore/scan-action`) | Fails on HIGH/CRITICAL vulnerabilities |
| Security Scan | Trivy (`aquasecurity/trivy-action`) | Fails on HIGH/CRITICAL vulns + secrets in the image |
| Publish | Skopeo | Server-side copy of the scanned image to the published namespace |

## Registry

- Build / scan / publish target: OTC SWR, `swr.eu-de.otc.t-systems.com`.
- Staging namespace: `eopaas-test` (assumed; set via the `SWR_STAGING_ORG` variable).
- Published namespace: `eopaas`, tag `:latest`.
- The Dockerfile base image is still pulled from the internal Harbor (`core.harbor.dev.eoss-cloud.it`) at build time.

## Configuration

All secrets and variables should be set once at the `cgi-italy` organization level so new child repos need no per-repo setup. See [credentials.txt](credentials.txt) for the full manifest (names and purpose only).

## Creating a new processor repo

Use `new-repo.sh` (requires the `gh` CLI):

```sh
./new-repo.sh inspect        # read-only: show the template/org config a new repo needs
./new-repo.sh create         # create a new repo from cgi-italy/processor-template
```

The child repo only needs a `.github/workflows/` that calls this pipeline and its app under `code/` (with a `Dockerfile`). The `processor-template` repo already has both.
