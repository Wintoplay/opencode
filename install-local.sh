#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

if [[ -z "${HOME:-}" ]]; then
  printf 'HOME must be set to choose an install directory.\n' >&2
  exit 1
fi

path_only=false
case "${1:-}" in
  "") ;;
  --path-only) path_only=true ;;
  *)
    printf 'Usage: %s [--path-only]\n' "${BASH_SOURCE[0]}" >&2
    exit 1
    ;;
esac

if [[ -n "${OPENCODE_INSTALL_DIR:-}" ]]; then
  install_dir="$OPENCODE_INSTALL_DIR"
elif [[ -n "${XDG_BIN_DIR:-}" ]]; then
  install_dir="$XDG_BIN_DIR"
elif [[ -d "$HOME/bin" || -w "$HOME" ]]; then
  install_dir="$HOME/bin"
else
  install_dir="$HOME/.opencode/bin"
fi
if [[ "$install_dir" != /* ]]; then
  install_dir="$repo_root/$install_dir"
fi

configure_path() {
  local startup_file
  local shell_name="${SHELL:-/bin/bash}"
  case "${shell_name##*/}" in
    bash) startup_file="$HOME/.bashrc" ;;
    zsh) startup_file="$HOME/.zshrc" ;;
    *) startup_file="$HOME/.profile" ;;
  esac

  local path_line="export PATH=$(printf '%q' "$install_dir"):\$PATH"
  if [[ -f "$startup_file" ]] && grep -Fqx "$path_line" "$startup_file"; then
    printf 'PATH is already configured in %s\n' "$startup_file"
  elif printf '\n# OpenCode local install\n%s\n' "$path_line" >> "$startup_file"; then
    printf 'Added the install directory to PATH in %s\n' "$startup_file"
  else
    printf 'Could not update %s. Add this line manually:\n  %s\n' "$startup_file" "$path_line" >&2
    printf 'For this terminal, run:\n  export PATH=%q:"$PATH"\n' "$install_dir"
    return
  fi
  printf 'Load the PATH change in this terminal with:\n  source %q\n' "$startup_file"
}

if [[ "$path_only" == true ]]; then
  if [[ ! -x "$install_dir/opencode" ]]; then
    printf 'No installed OpenCode executable at %s/opencode\n' "$install_dir" >&2
    exit 1
  fi
  configure_path
  exit 0
fi

if ! command -v bun >/dev/null 2>&1; then
  printf 'Bun is required. Install Bun, then run this script again.\n' >&2
  exit 1
fi

runtime="$(bun -e 'console.log(`${process.platform} ${process.arch}`)')"
read -r platform arch <<< "$runtime"

case "$platform" in
  linux | darwin) ;;
  *)
    printf 'Unsupported operating system: %s (expected Linux or macOS).\n' "$platform" >&2
    exit 1
    ;;
esac

case "$arch" in
  x64 | arm64) ;;
  *)
    printf 'Unsupported CPU architecture: %s (expected x64 or arm64).\n' "$arch" >&2
    exit 1
    ;;
esac

libc=
if [[ "$platform" == linux ]] && command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
  libc=musl
fi

printf 'Installing dependencies...\n'
bun install --frozen-lockfile

build_channel="${OPENCODE_CHANNEL:-$(git branch --show-current)}"
build_channel="${build_channel:-v2}"
build_version="${OPENCODE_VERSION:-$(bun -e 'console.log((await Bun.file("packages/cli/package.json").json()).version)')}"
export OPENCODE_CHANNEL="$build_channel"
export OPENCODE_VERSION="$build_version"
printf 'Build version %s on channel %s\n' "$build_version" "$build_channel"

target="opencode-$platform-$arch"
if [[ -n "$libc" ]]; then
  target="$target-$libc"
  printf 'Building OpenCode for %s-%s-%s...\n' "$platform" "$arch" "$libc"
  bun run --cwd packages/cli build "--target=$target" --skip-install
else
  printf 'Building OpenCode for %s-%s...\n' "$platform" "$arch"
  bun run --cwd packages/cli build --single --skip-install
fi

binary="$repo_root/packages/cli/dist/cli-$platform-$arch${libc:+-$libc}/bin/opencode"
if [[ ! -x "$binary" ]]; then
  printf 'Build finished without the expected executable: %s\n' "$binary" >&2
  exit 1
fi

mkdir -p "$install_dir"
temporary_binary="$install_dir/.opencode.$$"
trap 'rm -f "$temporary_binary"' EXIT
cp "$binary" "$temporary_binary"
chmod 755 "$temporary_binary"
mv -f "$temporary_binary" "$install_dir/opencode"
trap - EXIT

printf 'Installed %s\n' "$install_dir/opencode"
configure_path
