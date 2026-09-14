# OpenEMR on Podman — Local Deployment

Run the full OpenEMR 8.4.0 stack on your laptop. No cluster, no `oc`, no login.
Works on x86_64 and Apple Silicon.

For the OpenShift deployment, see the [main README](../README.md).

## Quick start

```bash
cd podman
./deploy-local.sh
```

First run takes a few minutes — it pulls or builds the image, starts MariaDB,
and loads the schema. When it finishes it prints the URL and admin password.

Then open **http://localhost:8080/**

## Prerequisites

| Platform      | Requirement                                            |
| ------------- | ------------------------------------------------------ |
| macOS         | Podman Desktop or `brew install podman`, then `podman machine start` |
| Linux         | `podman` (rootless is fine)                            |
| Windows       | Podman Desktop with WSL2                               |

No `podman-compose`, no `docker`, no root.

## Commands

```bash
./deploy-local.sh            # deploy (default)
./deploy-local.sh --status   # pod, container, and volume state
./deploy-local.sh --logs     # follow the OpenEMR container log
./deploy-local.sh --down     # stop, keep the data
./deploy-local.sh --wipe     # remove everything including volumes
```

### Environment variables

| Variable        | Default                                     | Purpose                        |
| --------------- | ------------------------------------------- | ------------------------------ |
| `HOST_PORT`     | `8080`                                      | Host port to publish           |
| `BUILD_LOCAL`   | unset                                       | `1` forces a local image build |
| `OPENEMR_IMAGE` | `quay.io/ryan_nix/openemr-openshift:latest` | Override the published image   |

```bash
HOST_PORT=9090 ./deploy-local.sh      # if 8080 is taken
BUILD_LOCAL=1 ./deploy-local.sh       # build from the Containerfile
```

## Architecture handling

The published Quay image is built by GitHub Actions on an x64 runner, so it is
`amd64`. On Apple Silicon the script detects the mismatch and builds from
`../Containerfile` instead of running the image under emulation — emulating
nginx, PHP-FPM, Node and supervisord together is slow and unreliable.

Every base layer the build needs publishes `aarch64`: CentOS Stream 10, EPEL 10,
Remi's EL10 modular repos, and NodeSource. Expect 5–15 minutes for that build.

To check what the published image actually is:

```bash
podman image inspect quay.io/ryan_nix/openemr-openshift:latest --format '{{.Architecture}}'
```

If you'd rather skip the local build, publish a multi-arch manifest from CI with
`podman manifest` or `buildah manifest` and push both architectures under one
tag. The script uses the published image whenever it matches the host.

## How it differs from the OpenShift deployment

**One pod, three containers.** MariaDB, Redis, and OpenEMR share a network
namespace, so the app reaches the other two on `127.0.0.1`. No Services, no DNS,
no cluster networking.

**Named volumes instead of PVCs.** `openemr-mariadb-data` and `openemr-sites`
are ordinary Podman volumes. They survive `--down` and are destroyed by
`--wipe`.

**No Route, so no TLS.** This is the one behavioural difference that matters.
The image sets `session.cookie_secure = 1`, which is correct behind an
edge-terminated Route but means the browser will not return the session cookie
over plain `http://`. The symptom is a login page that loops rather than any
visible error, so the local deployment sets `OPENEMR_INSECURE_COOKIES=1`, which
drops a PHP override turning that flag off.

> Session cookies are not marked Secure in this mode. It is for local
> development and demos only — never expose this deployment beyond localhost,
> and never put real patient data in it.

**Credentials are reused across runs.** They live in
`openemr-local-credentials.txt` (mode 0600, gitignored). The container refuses
to start when the database was configured with a different password, so
deleting that file and redeploying onto existing volumes will break the stack.
If you want a genuinely clean start, use `--wipe`.

## Troubleshooting

**`Cannot reach the Podman engine`** — on macOS or Windows the engine runs in a
VM. Start it with `podman machine start`.

**Port 8080 already in use** — `HOST_PORT=9090 ./deploy-local.sh`.

**Login loops back to the login page** — the Secure-cookie override did not
take. Confirm it with:

```bash
podman exec openemr-openemr php -i | grep session.cookie_secure
```

**Blank page or a 500** — the schema probably did not load. Check the startup
log, which reports the schema version comparison explicitly:

```bash
./deploy-local.sh --logs
```

**Build fails on Apple Silicon** — check whether a package genuinely lacks an
`aarch64` build before assuming the whole path is broken; the failing `dnf`
line names it.

## Resource use

Roughly 2 GB RAM and 16 GB of disk for the images and volumes. On macOS the
podman machine default of 2 GB is tight — give it more if the build gets killed:

```bash
podman machine stop
podman machine set --memory 4096 --cpus 4
podman machine start
```
