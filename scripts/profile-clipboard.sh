#!/bin/bash
# Usage: [CONFIGURATION=Release] scripts/profile-clipboard.sh [ClassName[/testName] ...]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == --help ]]; then
  echo 'Usage: [CONFIGURATION=Debug|Release] scripts/profile-clipboard.sh [ClassName[/testName] ...]'
  echo 'Defaults to all ClipboardLatencyTests in Debug. Retains artifacts in the printed directory.'
  exit 0
fi
if (( $# == 0 )); then set -- ClipboardLatencyTests; fi

profile_summary=$(mktemp "${TMPDIR:-/tmp}/macshot-profile-summary.XXXXXX")
trap 'rm -f "$profile_summary"' EXIT
export CONFIGURATION="${CONFIGURATION:-Debug}"
export MACSHOT_KEEP_TEST_RESULTS=1
export TEST_RUNNER_MACSHOT_CLIPBOARD_BENCHMARK=1
export TEST_RUNNER_MACSHOT_SETTLED_COPY_BENCHMARK=1
export TEST_RUNNER_MACSHOT_BACKGROUND_STATE_BENCHMARK=1
export TEST_RUNNER_MACSHOT_PRESENTATION_CACHE_BENCHMARK=1

scripts/run-tests.sh "$@" | tee "$profile_summary"

python3 - "$profile_summary" "$CONFIGURATION" "$@" <<'PY'
import datetime
import pathlib
import platform
import re
import subprocess
import sys

summary = pathlib.Path(sys.argv[1]).read_text()
artifact_lines = re.findall(r"^Test artifacts: (.+)$", summary, re.MULTILINE)
if not artifact_lines:
    sys.exit("Profiling finished without a retained artifact directory.")
directory = pathlib.Path(artifact_lines[-1])
log = (directory / "xcodebuild.log").read_text(errors="replace")
metrics = [line for line in log.splitlines() if re.match(
    r"^(CLIPBOARD_READY|CLIPBOARD_BENCH|CLIPBOARD_FILTER|SETTLED_COPY_BENCHMARK|"
    r"BACKGROUND_STATE_BENCHMARK)\b|^Native presentation reuse,", line)]
if not metrics:
    sys.exit(f"No benchmark measurements found. Inspect {directory / 'xcodebuild.log'}")
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip())
report = directory / "clipboard-profile.txt"
report.write_text("\n".join([
    f"Recorded: {datetime.datetime.now(datetime.timezone.utc).isoformat()}",
    f"Revision: {revision}; uncommitted changes: {dirty}",
    f"Configuration: {sys.argv[2]}",
    f"System: macOS {platform.mac_ver()[0]}, {platform.machine()}",
    f"Test filters: {' '.join(sys.argv[3:])}",
    "Scope: synthetic benchmarks; excludes physical key delivery and controller teardown.",
    "Compare runs with the same configuration, fixture geometry, and machine.",
    "", *metrics, "",
]))
print(report.read_text(), end="")
print(f"Saved profiling report: {report}")
PY
