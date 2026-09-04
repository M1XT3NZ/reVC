#!/usr/bin/env bash
#
# Cloud Agent install script for reVC (Linux, librw gl3/glfw + OpenAL).
#
# Reproduces the repository's "Linux Conan" build documented in README.md and the
# build-cmake-conan.yml CI workflow. It is idempotent: re-running it re-uses the
# conan cache and only rebuilds what changed.
#
set -euo pipefail

# Resolve repo root (this script lives in <repo>/.cursor/).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

export PATH="${HOME}/.local/bin:${PATH}"

# ---------------------------------------------------------------------------
# 1. System packages: build toolchain + OpenGL headers.
#    (glfw's transitive X11 dev packages are installed by conan itself, see the
#     tools.system.package_manager config below.)
# ---------------------------------------------------------------------------
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
	build-essential git curl ca-certificates \
	python3 python3-pip python3-yaml \
	libgl-dev libgl1-mesa-dev

# ---------------------------------------------------------------------------
# 2. Submodules. librw (the RenderWare reimplementation) is required to build.
# ---------------------------------------------------------------------------
git submodule update --init vendor/librw

# ---------------------------------------------------------------------------
# 3. Conan 1.x (the project is not yet Conan 2 compatible).
# ---------------------------------------------------------------------------
python3 -m pip install --user --upgrade "conan<2"

# ---------------------------------------------------------------------------
# 4. Conan configuration (idempotent).
# ---------------------------------------------------------------------------
conan config init
conan config set log.print_run_commands=True
conan config set general.revisions_enabled=1

# Allow conan to apt-install system requirements (glfw depends on xorg/system,
# which pulls in a long list of X11 -dev packages).
GLOBAL_CONF="${HOME}/.conan/global.conf"
if ! grep -q "tools.system.package_manager:mode" "${GLOBAL_CONF}" 2>/dev/null; then
	cat >>"${GLOBAL_CONF}" <<'EOF'
tools.system.package_manager:mode=install
tools.system.package_manager:sudo=True
EOF
fi

# Register the playstation2 OS and extra gcc versions in conan's settings so the
# ps2 cmake-toolchain recipe can be exported (mirrors the CI workflow). Harmless
# on non-ps2 builds.
python3 - <<'PY'
import os, yaml
path = os.path.expanduser("~/.conan/settings.yml")
data = yaml.safe_load(open(path))
data["os"].setdefault("playstation2", None)
versions = data["compiler"]["gcc"]["version"]
for extra in ("3.2", "15"):
    if extra not in versions:
        versions.append(extra)
data["compiler"]["gcc"]["version"] = sorted(set(versions))
yaml.safe_dump(data, open(path, "w"))
PY

# On this base image /usr/bin/c++ and /usr/bin/cc resolve to clang (via
# update-alternatives). clang selects the newest installed gcc toolchain for
# libstdc++, but only libstdc++-13-dev ships the linker symlink, so C++ linking
# fails ("cannot find -lstdc++"). Conan's detected profile already uses gcc, so
# pin the compiler executables to gcc/g++ to match it.
DEFAULT_PROFILE="${HOME}/.conan/profiles/default"
if ! grep -q '^CC=' "${DEFAULT_PROFILE}"; then
	printf 'CC=gcc\nCXX=g++\n' >>"${DEFAULT_PROFILE}"
fi

# Host profile used for the reVC/librw packages (built for the host).
HOST_PROFILE="${HOME}/revc_host_profile"
cp "${DEFAULT_PROFILE}" "${HOST_PROFILE}"

# ---------------------------------------------------------------------------
# 5. Export the conan recipes the build depends on.
# ---------------------------------------------------------------------------
conan export vendor/librw/cmake/ps2/cmaketoolchain ps2dev-cmaketoolchain/master@
cp .github/conan/librw-conanfile.py vendor/librw/conanfile.py
conan export vendor/librw librw/master@

# ---------------------------------------------------------------------------
# 6. Resolve/build dependencies, then build reVC itself.
# ---------------------------------------------------------------------------
export CONAN_SYSREQUIRES_MODE=enabled
conan install "${REPO_ROOT}" reVC/master@ -if build \
	-o reVC:audio=openal -o librw:platform=gl3 -o librw:gl3_gfxlib=glfw \
	--build missing -pr:h "${HOST_PROFILE}" -pr:b default \
	-s reVC:build_type=RelWithDebInfo -s librw:build_type=RelWithDebInfo

conan build "${REPO_ROOT}" -if build -bf build -pf package

echo "reVC build complete: ${REPO_ROOT}/build/reVC/src/reVC"
