# Grading platform

Deployment definition for the Autolab installation at
`https://grading.dos.cit.tum.de`. This repository contains no courses,
assignments, submissions, or private tests.

The trusted services are split across two machines:

- the Ubuntu 26.04 VM at `grading.dos.cit.tum.de` runs Autolab, MySQL, and the
  public nginx/TLS endpoint;
- Astrid runs Tango and Redis, with Tango bound only to localhost behind an
  nginx HTTPS endpoint that accepts the web VM's address;
- Tango has no Docker socket and uses a least-privilege kubeconfig to create
  short-lived Jobs and Secrets in the `grading` namespace;
- persistent Docker volumes hold each machine's application state.

`flake.nix` exports the NixOS module used on Astrid. It owns Tango, the runtime
kubeconfig, the restricted HTTPS proxy, and an Ansible systemd service that
reconciles the Ubuntu VM. The cluster-config repository supplies the deploy key
and both SOPS-managed environment files through systemd credentials.

The Autolab image is built from upstream v3.0.2 commit
`96006d532a392eeca2d350d1811f8e8ab9625bda`. The workflow adds only the
non-secret production configuration in `autolab-config/`. Tango is built by
the separate `tango-kubernetes` repository. Application images must be public
in GHCR so neither Tango nor grading Jobs need registry credentials.

## First deployment

The VM must initially contain the dedicated public key for its `deploy` user.
Astrid pins its SSH host key and uses the encrypted private key from the
cluster-config repository. PIRA owns the public website's certificate enrollment
and renewal on the Ubuntu VM. The defaults use the files you listed:
`/etc/pira-client/live/host:f:dosvm6.cit.tum.de.fullchain.pem` and
`/etc/pira-client/live/host:f:dosvm6.cit.tum.de.privkey.pem`. That certificate must
cover `grading.dos.cit.tum.de`. The playbook installs Docker, Compose, nginx, and
unattended upgrades; installs the pinned Compose definition and secrets; starts
Autolab/MySQL; and runs migrations.

The NixOS configuration generates `/run/grading/tango.kubeconfig` from the
namespaced ServiceAccount. It never transfers that credential to the web VM.

### Internal Tango TLS

Astrid generates a self-signed CA in `/var/lib/grading-tls` on first activation.
It issues a 90-day server certificate for `astrid.dos.cit.tum.de`, checking daily
and renewing when fewer than 30 days remain. nginx reloads after renewal.
The CA lasts ten years; back up this directory securely and replace the CA
before it expires. Its private key and the server private key stay on Astrid.

Provisioning copies only `ca.crt` over the authenticated SSH connection to the
VM. Autolab mounts it read-only and installs it into the container's system
trust store before the application starts. Certificate and hostname verification
remain enabled. Tango's nginx endpoint listens on port 3000 and permits only the
web VM's source address. No PIRA certificate or ACME service is needed on Astrid.

After deployment, test the actual Autolab client from the VM:

```console
sudo docker compose --env-file /etc/grading-platform/.env \
  --file /etc/grading-platform/compose.yaml exec autolab \
  bundle exec rails runner 'require Rails.root.join("lib/tango_client"); puts TangoClient.info'
```

Database migrations are automatic. Creating the first administrator remains a
one-time application action on the VM:

```console
sudo docker compose --env-file /etc/grading-platform/.env \
  --file /etc/grading-platform/compose.yaml exec autolab \
  bundle exec rails db:prepare
sudo docker compose --env-file /etc/grading-platform/.env \
  --file /etc/grading-platform/compose.yaml exec autolab \
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
