#!/usr/bin/env bash
# One command = the entire QA chain that does not need a MetaTrader 5 terminal.
#
#   bash tools/run_all_qa.sh
#
# Exit status is 0 only when every step passes. This is the checklist gate: do not
# package, publish, or hand this tree to a broker account unless it prints
# "ALL QA STEPS PASSED".
set -u
cd "$(dirname "$0")/.." || exit 1
PY=python3; command -v python3 >/dev/null || PY=python
fail=0

echo "[1/9] required files present"
for f in \
  MQL5/Experts/XAU_AVG_PRO.mq5 \
  MQL5/Include/XAU_AVG_PRO/{Types,BrokerSpec,Logger,StateStore,Cycle,Execution,Entry,Averaging,Lots,MarketFilters,News,Basket,Risk,Dashboard,Telegram,SelfTest,State,Statistics}.mqh \
  docs/{01-architecture,02-input-specification,03-state-machine,04-risk-model,05-averaging-algorithm,06-cycle-and-position-management,07-telegram-command-spec,08-testing-strategy,09-known-risks-and-limitations,10-installation-and-configuration,11-backtest-protocol,12-stress-test-report,13-code-audit,14-risk-disclaimer}.md \
  presets/XAU_AVG_PRO_conservative.set presets/XAU_AVG_PRO_cent_account.set \
  presets/XAU_AVG_PRO_multiplier_demo.set \
  README.md CHANGELOG.md \
  tools/{mql_values,gen_input_docs,gen_preset,qa_preset_check,qa_doc_claims,qa_static_check,qa_mql_symbol_check,stress_model}.py ; do
  [ -f "$f" ] || { echo "    MISSING: $f"; fail=1; }
done
[ $fail -eq 0 ] && echo "    ok ($(ls MQL5/Experts/*.mq5 MQL5/Include/XAU_AVG_PRO/*.mqh docs/*.md presets/*.set README.md CHANGELOG.md tools/*.py tools/run_all_qa.sh | wc -l) deliverables present)"

echo "[2/9] MQL5 static checks (markers, strings, braces, guards, handlers, formats, mirrors)"
$PY tools/qa_static_check.py >/tmp/qa_static.log 2>&1 || { echo "    FAIL - see below"; tail -20 /tmp/qa_static.log; fail=1; }
tail -1 /tmp/qa_static.log

echo "[3/9] MQL5 symbol/signature checks (builtins, structs, members, enum values, config fields)"
$PY tools/qa_mql_symbol_check.py >/tmp/qa_sym.log 2>&1 || { echo "    FAIL - see below"; tail -25 /tmp/qa_sym.log; fail=1; }
grep -E "calls resolved|field accesses" /tmp/qa_sym.log; tail -1 /tmp/qa_sym.log

echo "[4/9] docs/02 is generated from the source, not written by hand"
$PY tools/gen_input_docs.py --check >/dev/null 2>&1 || { echo "    FAIL: run 'python3 tools/gen_input_docs.py' and commit"; fail=1; }
grep -m1 -E "input|Input" docs/02-input-specification.md | cut -c1-100

echo "[5/9] presets: complete, type-legal, manifest-accurate, secret-free"
$PY tools/qa_preset_check.py >/tmp/qa_presets.log 2>&1 || { echo "    FAIL - see below"; grep -E "PROBLEM|!|FAIL" /tmp/qa_presets.log | head -12; fail=1; }
tail -1 /tmp/qa_presets.log

echo "[6/9] documentation counts match the source (README / CHANGELOG / docs)"
$PY tools/qa_doc_claims.py --evidence /tmp/qa_sym.log >/tmp/qa_docs.log 2>&1 || { echo "    FAIL - see below"; grep -E "FAIL|mismatch" /tmp/qa_docs.log | head -12; fail=1; }
tail -1 /tmp/qa_docs.log

echo "[7/9] secret and placeholder scan across every deliverable"
secrets=0
# a real Telegram bot token is "<8-10 digits>:<35+ urlsafe chars>" - that shape, not the
# word "token", is what must never appear in the tree
if grep -rnE "[0-9]{8,10}:[A-Za-z0-9_-]{30,}" --include='*.md' --include='*.mq5' \
      --include='*.mqh' --include='*.set' . 2>/dev/null | grep -v '^./tools/'; then
  echo "    FAIL: something shaped like a Telegram bot token is present"; secrets=1
fi
for pat in 'YOUR_TOKEN' 'BOT_TOKEN_HERE' 'CHANGE_ME' 'xxxxx:'; do
  hits=$(grep -rn "$pat" --include='*.md' --include='*.mq5' --include='*.mqh' --include='*.set' . 2>/dev/null | grep -v '^./tools/')
  if [ -n "$hits" ]; then echo "    FAIL: secret-like value '$pat':"; echo "$hits" | head -3; secrets=1; fi
done
# inputs must ship empty, so nobody's credentials end up in git
if ! grep -qE '^TelegramBotToken=$' presets/*.set 2>/dev/null || \
   grep -qE '^TelegramBotToken=.+' presets/*.set; then
  echo "    FAIL: presets must ship 'TelegramBotToken=' (empty)"; secrets=1
fi
if grep -rnE 'TelegramBotToken[[:space:]]*=[[:space:]]*"[^"]' MQL5/ 2>/dev/null; then
  echo "    FAIL: the token input has a literal default"; secrets=1
fi
placeholders=0
for pat in 'TODO' 'FIXME' 'XXX' 'IMPLEMENT LATER' 'PLACEHOLDER' 'STUB' 'not implemented' 'pseudo-code'; do
  hits=$(grep -rn "$pat" --include='*.mq5' --include='*.mqh' --include='*.set' . 2>/dev/null | grep -v '^./tools/')
  if [ -n "$hits" ]; then echo "    FAIL: placeholder marker '$pat' in code/preset:"; echo "$hits" | head -3; placeholders=1; fi
done
for pat in 'will be implemented' 'not yet implemented' 'coming soon' 'for now, this is'; do
  hits=$(grep -rni "$pat" --include='*.md' . 2>/dev/null | grep -v '^./tools/')
  if [ -n "$hits" ]; then echo "    FAIL: documentation promises unimplemented work ('$pat'):"; echo "$hits" | head -3; placeholders=1; fi
done
[ $secrets -eq 0 ] && [ $placeholders -eq 0 ] && echo "    ok (no secret shapes, no placeholder markers in code)"
[ $secrets -eq 1 ] && fail=1
[ $placeholders -eq 1 ] && fail=1

echo "[8/9] stress model reproduces the published numbers in docs/12"
cp docs/12-stress-test-report.md /tmp/d12.md
$PY tools/stress_model.py --emit-doc /tmp/d12.md >/dev/null 2>&1 || { echo "    FAIL: model error"; fail=1; }
if diff -q /tmp/d12.md docs/12-stress-test-report.md >/dev/null 2>&1; then
  echo "    ok (docs/12 is byte-identical to the model output - no hand-copied numbers)"
else
  echo "    FAIL: docs/12 drifted from tools/stress_model.py - run: python3 tools/stress_model.py --emit-doc docs/12-stress-test-report.md"
  fail=1
fi

echo "[9/9] MQL5 compilation"
if command -v mql5-compile >/dev/null 2>&1 || ls /Applications/MetaTrader\ 5.app >/dev/null 2>&1 || command -v metaeditor64.exe >/dev/null 2>&1; then
  echo "    MetaEditor found - running it"
  mql5-compile MQL5/Experts/XAU_AVG_PRO.mq5 || fail=1
else
  echo "    NOT AVAILABLE IN CURRENT ENVIRONMENT"
  echo "    There is no MetaEditor/MetaTrader 5 in this Linux sandbox and MQL5 cannot be"
  echo "    compiled from it, so 0 errors / 0 warnings has never been asserted here."
  echo "    Run locally:  metaeditor64.exe /compile:MQL5\\Experts\\XAU_AVG_PRO.mq5 /log"
  echo "    Then re-run the QA chain:  bash tools/run_all_qa.sh"
fi

echo
if [ $fail -eq 0 ]; then
  echo "ALL QA STEPS PASSED"
  echo "Steps 1-8 are the complete non-terminal chain; step 9 is the only known gap"
  echo "(docs/13.5). Not covered here: any live broker interaction - use docs/08 tests A-V."
else
  echo "QA FAILED"
  exit 1
fi
