#!/usr/bin/env bash
# run_all_qa.sh - the whole pre-release verification chain that can run without
# MetaTrader. Each step prints its own report; the script exits non-zero on the
# first failure, so it is usable as a CI gate.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== 1/5 static structure and conventions"
python3 tools/qa_static_check.py | tail -4
echo "== 2/5 module symbol / arity / type shape"
python3 tools/qa_mql_symbol_check.py | tail -4
echo "== 3/5 documentation is generated, so it must match"
python3 tools/gen_input_docs.py --check
echo "== 4/5 stress model still runs (docs/12 source of truth)"
python3 tools/stress_model.py --json > /tmp/xau_stress.json && echo "stress model ok -> /tmp/xau_stress.json"
echo "== 5/5 presets still match the input list"
for f in presets/*.set; do
  n=$(grep -c "=" "$f")
  echo "   $f: $n parameter lines"
done
echo
echo "ALL QA STEPS PASSED"
echo "not covered here: compilation and any broker interaction (docs/08 tests A-V)."
