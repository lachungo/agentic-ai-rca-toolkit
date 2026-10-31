#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if find "$root_dir" -type f -iname '*.xel' -print -quit | grep -q .; then
  echo "FAIL: raw XEL telemetry is present"
  exit 1
fi

required=(
  "README.md"
  "LICENSE"
  "SECURITY.md"
  "docs/DEPLOYMENT.md"
  "sql/engine/01_RCA_Lab_Build.sql"
  "sql/operations/RCA_V1_SCRIPT_111N_v1.3_Deploy_Multi_Culprit_Flight_Recorder_HTML.sql"
  "sql/acceptance/RCA_V1_SCRIPT_111O_v1.1_RCA_Demo_Blocking_CPU_Memory_Multi_Request_Positive_Control.sql"
  "examples/RCA_Incident_Certified_Multi_Culprit.html"
)

for path in "${required[@]}"; do
  if [[ ! -s "$root_dir/$path" ]]; then
    echo "FAIL: missing required file: $path"
    exit 1
  fi
done

sql_count="$(find "$root_dir/sql" -type f -iname '*.sql' | wc -l | tr -d ' ')"
echo "PASS: package contains $sql_count SQL scripts and no raw XEL telemetry"
