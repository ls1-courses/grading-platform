# Grading platform

Deployment definition for the Autolab installation at
`https://grading.dos.cit.tum.de`. This repository contains no courses,
assignments, submissions, or private tests.

The trusted stack runs on Astrid with Docker Compose:

- Autolab is the only service published on the host, at `127.0.0.1:8080`;
- host nginx terminates TLS and proxies the public hostname to Autolab;
- Tango, Redis, and MySQL are reachable only on the internal Compose network;
- Tango has no Docker socket and uses a least-privilege kubeconfig to create
  short-lived Jobs and Secrets in the `grading` namespace;
- persistent Docker volumes hold the database and Autolab/Tango state.

`flake.nix` exports the NixOS module that owns Docker, the systemd Compose
unit, the runtime kubeconfig, nginx, ACME, and ports 80/443. The cluster-config
repository imports this module and supplies its SOPS-managed environment file.

The Autolab image is built from upstream v3.0.2 commit
`96006d532a392eeca2d350d1811f8e8ab9625bda`. The workflow adds only the
non-secret production configuration in `autolab-config/`. Tango is built by
the separate `tango-kubernetes` repository. Application images must be public
in GHCR so neither Tango nor grading Jobs need registry credentials.

## First deployment

Do not put `.env` on the host. The NixOS configuration materializes the same
variables from SOPS as `/run/secrets/grading-platform.env` and generates
`/run/grading/tango.kubeconfig` from the namespaced ServiceAccount.

After the NixOS service has started the stack, initialize the database and the
first administrator once:

```console
docker compose --env-file /run/secrets/grading-platform.env exec autolab \
  bundle exec rails db:prepare
docker compose --env-file /run/secrets/grading-platform.env exec autolab \
  bundle exec rails admin:create_root_user[EMAIL,PASSWORD,FIRST,LAST]
```

Before the first start, set `TANGO_IMAGE` to the immutable Git SHA tag produced
by the Tango repository workflow. Keep database backups and the SOPS file in
the infrastructure repository; do not commit generated credentials here.

## Task and course repositories

Public task repositories own starter code, Nix image builds, public tests, and
GHCR publication. A separate private course repository owns Autolab course and
assessment bundles, private tests, scoring logic, and the mapping from each
assignment to an immutable task image reference.
