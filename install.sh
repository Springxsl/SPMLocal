#!/bin/bash
set -euo pipefail

# Installs the spm-install command from this checkout.
# PREFIX overrides the target directory, for example: PREFIX="$HOME/bin" ./install.sh

script_dir="$(cd "$(dirname "$0")" && pwd)"
source_file="$script_dir/spm-install.sh"

if [ ! -f "$source_file" ]; then
echo "install: $source_file is missing" >&2
exit 1
fi

for tool in git python3 swift; do
if ! command -v "$tool" >/dev/null 2>&1; then
echo "install: $tool is required but was not found on PATH" >&2
exit 1
fi
done

if [ -n "${PREFIX:-}" ]; then
target_dir="$PREFIX"
elif [ -w /usr/local/bin ]; then
target_dir="/usr/local/bin"
else
target_dir="$HOME/.local/bin"
fi

mkdir -p "$target_dir"
install -m 755 "$source_file" "$target_dir/spm-install"
echo "installed $target_dir/spm-install"

case ":$PATH:" in
*":$target_dir:"*)
;;
*)
echo "$target_dir is not on PATH. Add this line to ~/.zshrc:"
echo "  export PATH=\"$target_dir:\$PATH\""
;;
esac
