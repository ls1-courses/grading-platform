#!/bin/sh
set -eu

# Docker may create missing mount points as root. Run after volumes are mounted
# and before Passenger starts Rails as app. Keep existing contents untouched.
for directory in courses courseConfig assessmentConfig storage; do
  volume_path="/home/app/webapp/$directory"
  mkdir -p "$volume_path"
  chown app:app "$volume_path"
  chmod u+rwx "$volume_path"
done
