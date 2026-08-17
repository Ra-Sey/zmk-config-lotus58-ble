#!/usr/bin/env bash
# Build ZMK firmware locally in the same Docker image the GitHub Actions
# pipeline uses, mirroring the boards/shields listed in build.yaml.
#
# Usage:
#   ./build.sh          # incremental build
#   ./build.sh -p        # pristine (clean) build, e.g. after board/config changes

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="zmkfirmware/zmk-build-arm:stable"

PRISTINE_FLAG=""
if [[ "${1:-}" == "-p" || "${1:-}" == "--pristine" ]]; then
  PRISTINE_FLAG="-p"
fi

DOCKER_TTY_FLAG="-i"
if [ -t 1 ]; then
  DOCKER_TTY_FLAG="-it"
fi

docker run --rm $DOCKER_TTY_FLAG \
  --user "$(id -u):$(id -g)" \
  -e HOME=/workspace/.build-home \
  -v "$REPO_ROOT":/workspace \
  -w /workspace \
  "$IMAGE" \
  bash -c "
    set -euo pipefail
    mkdir -p \"\$HOME\"
    git config --global --add safe.directory '*'

    if [ ! -d .west ]; then
      west init -l config
      west update --fetch-opt=--filter=tree:0
      west zephyr-export
    fi

    # The real Zephyr checkout ends up at /workspace/zephyr (west's topdir
    # must equal the repo root here, since config/west.yml's self.path is
    # 'config'). Pointing ZMK_EXTRA_MODULES straight at /workspace would
    # make the module scanner treat that same checkout as this module's
    # 'zephyr/' metadata dir too, sourcing Kconfig.zephyr into itself.
    # Point it at a throwaway module root outside /workspace instead, with
    # an absolute board_root back to the real boards/ directory.
    mkdir -p /tmp/zmk-board-module/zephyr
    cat > /tmp/zmk-board-module/zephyr/module.yml <<'MODULE_EOF'
name: lotus58_ble
build:
  settings:
    board_root: /workspace
MODULE_EOF

    west build $PRISTINE_FLAG -s zmk/app -d build/left  -b lotus58_ble_left  -- -DZMK_CONFIG=/workspace/config -DZMK_EXTRA_MODULES=/tmp/zmk-board-module
    west build $PRISTINE_FLAG -s zmk/app -d build/right -b lotus58_ble_right -- -DZMK_CONFIG=/workspace/config -DZMK_EXTRA_MODULES=/tmp/zmk-board-module -DSHIELD=nice_view

    echo
    echo 'Left firmware:  build/left/zephyr/zmk.uf2'
    echo 'Right firmware: build/right/zephyr/zmk.uf2'
  "
