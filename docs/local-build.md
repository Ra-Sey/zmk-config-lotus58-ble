# Building Firmware Locally

The CI pipeline (`.github/workflows/build.yml`) delegates to ZMK's reusable
`build-user-config.yml` workflow, which builds every entry in
[`build.yaml`](../build.yaml) inside the `zmkfirmware/zmk-build-arm:stable`
Docker image. `build.sh` runs the exact same image and `west` commands
locally, so a build can be reproduced without pushing to GitHub.

## Prerequisites

- Docker (or a Docker-compatible runtime) installed and able to pull images
  from Docker Hub.

No local Zephyr SDK, ARM toolchain, or `west` install is required -- all of
that lives inside the container image.

## Installing Docker (Ubuntu/Debian)

Skip this section if `docker --version` already prints something. Otherwise,
step by step, for Ubuntu 24.04 ("Noble") or any Debian-based distribution
using `apt`:

1. **Check whether Docker is already installed.** Open a terminal and run:

   ```sh
   docker --version
   ```

   - If this prints a version (e.g. `Docker version 29.1.3, build ...`),
     Docker is installed -- skip to
     [Starting the Docker daemon](#starting-the-docker-daemon).
   - If it prints `command not found`, continue with step 2.

2. **Update the package index:**

   ```sh
   sudo apt update
   ```

3. **Install Docker.** Ubuntu ships a Docker package in its own repositories,
   which is the simplest option and enough for building ZMK firmware:

   ```sh
   sudo apt install docker.io
   ```

   (If you specifically want Docker's own upstream package instead --
   e.g. for a newer version -- follow
   [Docker's official install guide for Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
   instead of this step; everything from step 4 onward applies either way.)

4. **Confirm the install:**

   ```sh
   docker --version
   ```

   This should now print a version string.

5. **Let your user run `docker` without `sudo`.** By default only `root` and
   members of the `docker` group can talk to the Docker daemon. Add yourself
   to that group:

   ```sh
   sudo usermod -aG docker "$USER"
   ```

   This does not take effect in your *current* login session. Either log out
   and log back in (or reboot), or run the following in every terminal you
   want it active in right away:

   ```sh
   newgrp docker
   ```

   Verify group membership:

   ```sh
   groups
   ```

   `docker` should now be listed. If you skip this step, every `docker` and
   `./build.sh` invocation needs `sudo` in front of it instead.

## Starting the Docker daemon

`docker run` (and therefore `build.sh`) talks to a background service, the
Docker daemon (`dockerd`), which must be running first. On Ubuntu it's
managed by `systemd`.

1. **Check whether it's already running:**

   ```sh
   systemctl is-active docker
   ```

   - Prints `active` -- the daemon is running, nothing to do; skip to
     [Verifying the setup](#verifying-the-setup).
   - Prints `inactive` or `failed` -- continue with step 2.

2. **Start it:**

   ```sh
   sudo systemctl start docker
   ```

3. **Make it start automatically on every boot** (so you don't need to
   repeat step 2 after restarting your machine):

   ```sh
   sudo systemctl enable docker
   ```

4. **Confirm it's running:**

   ```sh
   systemctl status docker
   ```

   Look for `Active: active (running)` near the top of the output. Press `q`
   to leave the status view.

## Verifying the setup

Run Docker's smoke-test image. If everything above is in place, this needs
no `sudo`:

```sh
docker run --rm hello-world
```

Expected output includes the line `Hello from Docker!` followed by an
explanation of what just happened. Docker downloads the tiny `hello-world`
image on first use, runs it, and removes the container again (`--rm`).

If this fails with `permission denied while trying to connect to the Docker
daemon socket`, the group membership from step 5 above hasn't taken effect
yet in this terminal -- open a new terminal (or run `newgrp docker`) and try
again. If it fails with `Cannot connect to the Docker daemon`, the daemon
isn't running -- go back to
[Starting the Docker daemon](#starting-the-docker-daemon).

Once `docker run --rm hello-world` succeeds, `./build.sh` (see
[Usage](#usage) below) will work the same way -- its first run additionally
downloads the much larger `zmkfirmware/zmk-build-arm:stable` build image
(roughly 1-2 GB) plus the ZMK/Zephyr sources (also roughly 1-2 GB), so expect
that first invocation to take several minutes depending on your connection.

## Usage

```sh
./build.sh          # incremental build
./build.sh -p        # pristine (clean) build -- use after changing a board,
                      # shield, or west.yml/build.yaml
```

Firmware output:

- Left half: `build/left/zephyr/zmk.uf2`
- Right half (with `nice_view` shield): `build/right/zephyr/zmk.uf2`

Flash by putting the half into bootloader mode (double-tap reset) and
copying the corresponding `.uf2` file to the `NICENANO`/bootloader USB mass
storage device that appears.

## How it works

On first run, `build.sh` turns the repository itself into a west workspace,
exactly like `west init -l config` does in the CI workflow:

1. `west init -l config` -- registers this repo's `config/` as the manifest
   project (see [`config/west.yml`](../config/west.yml)).
2. `west update` -- clones `zmk`, `zephyr`, and the other modules referenced
   by ZMK's manifest as siblings at the repository root (`zmk/`, `zephyr/`,
   `modules/`, `bootloader/`, `tools/`). These are gitignored.
3. `west zephyr-export` -- registers the Zephyr CMake package so `west
   build` can find it.

Every subsequent run skips straight to `west build` for both halves listed
in `build.yaml`, using the out-of-tree board definition under
[`boards/tweetydabird/lotus58_ble/`](../boards/tweetydabird/lotus58_ble/)
via `-DZMK_CONFIG=/workspace/config -DZMK_EXTRA_MODULES=...`. The latter is
what makes CMake find the custom board at all -- ZMK's manifest self project
is rooted at `config/`, not the repository root, so without it CMake reports
"Invalid BOARD". The CI workflow (`build-user-config.yml`) does the same,
pointing `ZMK_EXTRA_MODULES` at `$GITHUB_WORKSPACE` (there, that directory
only holds the small checked-out user-config repo, since the actual Zephyr
checkout happens elsewhere).

Locally, the west workspace topdir has to be the repository root itself
(`config/west.yml`'s `self.path: config` forces that), which means
`west update` clones the *real* Zephyr RTOS straight into `/workspace/zephyr`
-- the same directory that holds this repo's own
[`zephyr/module.yml`](../zephyr/module.yml) (`board_root: .`). Pointing
`ZMK_EXTRA_MODULES` directly at `/workspace` would make the build treat that
real Zephyr checkout as this module's own `zephyr/` metadata directory too,
which sources `Kconfig.zephyr` into itself and aborts with a "recursive
'source'" error. `build.sh` therefore writes a throwaway module descriptor to
`/tmp/zmk-board-module/zephyr/module.yml` (inside the container, never
touching the repo) with an *absolute* `board_root: /workspace`, and passes
that directory as `ZMK_EXTRA_MODULES` instead.

The container runs as your host UID/GID (`--user "$(id -u):$(id -g)"`) with
`$HOME` pointed at `.build-home/` inside the repo (also gitignored), so
files created by the build stay owned by you instead of `root`.

## Updating to a newer ZMK

`config/west.yml` pins `revision: main`. To pick up upstream ZMK changes,
delete the west workspace state and let `build.sh` re-initialize it:

```sh
rm -rf .west zmk zephyr/* modules bootloader tools build .build-home
git checkout zephyr/module.yml   # restore the file .gitignore excludes zephyr/* from
./build.sh
```
