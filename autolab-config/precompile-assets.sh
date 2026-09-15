#!/bin/sh
set -eu

# Rails loads production initializers during asset compilation. These public
# placeholders exist only in this build process; Compose supplies real values
# at runtime. No database or Tango service is required for asset compilation.
exec env \
  RAILS_ENV=production \
  SECRET_KEY_BASE=0000000000000000000000000000000000000000000000000000000000000000 \
  DEVISE_SECRET_KEY=0000000000000000000000000000000000000000000000000000000000000000 \
  LOCKBOX_MASTER_KEY=0000000000000000000000000000000000000000000000000000000000000000 \
  MYSQL_DATABASE=autolab_asset_build \
  MYSQL_USER=asset_build \
  MYSQL_PASSWORD=asset_build_placeholder \
  MYSQL_HOST=127.0.0.1 \
  RESTFUL_HOST=http://127.0.0.1 \
  RESTFUL_PORT=3000 \
  RESTFUL_KEY=asset_build_placeholder \
  bundle exec rails assets:precompile
