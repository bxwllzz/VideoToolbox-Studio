#!/usr/bin/env bash
set -euo pipefail

readonly xcodegen_version="${XCODEGEN_VERSION:-2.46.0}"
readonly install_root="${XCODEGEN_INSTALL_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xcodegen-${xcodegen_version}}"
readonly archive_path="${install_root}/xcodegen.zip"
readonly download_url="https://github.com/yonaskolb/XcodeGen/releases/download/${xcodegen_version}/xcodegen.zip"

mkdir -p "${install_root}"

if [[ ! -f "${archive_path}" ]]; then
  curl \
    --proto '=https' \
    --tlsv1.2 \
    --fail \
    --show-error \
    --location \
    --retry 3 \
    --output "${archive_path}" \
    "${download_url}"
fi

unzip -q -o "${archive_path}" -d "${install_root}"

xcodegen_binary="$(find "${install_root}" -type f -name xcodegen -print -quit)"
if [[ -z "${xcodegen_binary}" ]]; then
  echo "错误：XcodeGen 压缩包中未找到可执行文件。" >&2
  exit 1
fi

chmod +x "${xcodegen_binary}"
xcodegen_bin_directory="$(dirname "${xcodegen_binary}")"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${xcodegen_bin_directory}" >> "${GITHUB_PATH}"
fi

"${xcodegen_binary}" version
