#!/usr/bin/env bash
# Run the Vector parser unit tests against the journal-source fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="$(grep -m1 '^    image: timberio/vector' compose.yaml | awk '{print $2}')"

python3 tests/gen_tests.py

echo "Running vector unit tests (${IMAGE})..."
docker run --rm \
  -v "$PWD/collector/vector.toml:/opt/vector.toml:ro" \
  -v "$PWD/tests/generated_tests.toml:/opt/tests.toml:ro" \
  --entrypoint vector "$IMAGE" test --no-environment /opt/vector.toml /opt/tests.toml
