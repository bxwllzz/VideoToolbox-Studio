#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "用法：$0 <App 路径> <构建信息 JSON> <输出目录>" >&2
  exit 2
fi

readonly app_path="$1"
readonly build_info_path="$2"
readonly output_directory="$3"

if [[ ! -d "${app_path}" ]]; then
  echo "错误：未找到 App 包：${app_path}" >&2
  exit 1
fi

if [[ ! -f "${build_info_path}" ]]; then
  echo "错误：未找到构建信息：${build_info_path}" >&2
  exit 1
fi

readonly commit_sha="${BUILD_COMMIT_SHA:-${GITHUB_SHA:-local}}"
readonly short_commit="${commit_sha:0:12}"
readonly ipa_name="VideoToolboxStudio-${short_commit}.ipa"
readonly staging_directory="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/VideoToolboxStudio-Package"

rm -rf "${staging_directory}"
mkdir -p "${staging_directory}/Payload" "${output_directory}"

ditto "${app_path}" "${staging_directory}/Payload/VideoToolboxStudio.app"
cp "${build_info_path}" "${output_directory}/build-info.json"
cp "docs/SIDESTORE_INSTALL.md" "${output_directory}/INSTALL.md"

(
  cd "${staging_directory}"
  /usr/bin/zip -q -r "${output_directory}/${ipa_name}" Payload
)

(
  cd "${output_directory}"
  shasum -a 256 "${ipa_name}" > SHA256SUMS.txt
)

echo "已生成：${output_directory}/${ipa_name}"
