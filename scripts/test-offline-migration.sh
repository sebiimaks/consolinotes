#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_root="$(mktemp -d "${TMPDIR:-/tmp}/consolinotes-offline-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
swiftc -module-cache-path "$test_root/module-cache" \
  FSNotesCore/Business/SortBy.swift FSNotesCore/Business/SortDirection.swift \
  FSNotesCore/Business/ProjectSettings.swift FSNotesCore/LegacyNetworkCleanup.swift \
  tests/OfflineMigrationTests.swift -o "$test_root/offline-migration-tests"
"$test_root/offline-migration-tests"
