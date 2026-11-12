#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Planted-violation tests for scripts/check-internal-ids.py and its wiring into the git hooks (negative and positive
# controls). Each runs in a throw-away git repository under a temporary directory; nothing here is changed.
# Probe values are assembled at run time and the printed labels are neutral words, so neither this file nor its
# CI log contains an internal ID or a workspace path.
#
# Usage: scripts/test-id-gate.sh        Exit codes: 0 every control behaved as expected, 1 otherwise.
set -u

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
fail=0
pass=0
at=@
test_email="gate-test${at}example.invalid"

# expect <label> <expected exit code> <command...>   (output is shown on failure; the gate never prints a match)
expect() {
    label=$1
    want=$2
    shift 2
    "$@" > "$work/out.txt" 2>&1
    got=$?
    if [ "$got" -eq "$want" ]; then
        pass=$((pass + 1))
        echo "test-id-gate: $label PASS (exit $got)"
    else
        fail=$((fail + 1))
        echo "test-id-gate: $label FAIL (exit $got, expected $want):"
        sed 's/^/    /' "$work/out.txt" | head -8
    fi
}

mkdir -p "$work/repo"
cd "$work/repo" || exit 1
git init -q -b main .
git config user.name "Gate Test"
git config user.email "$test_email"
git config commit.gpgsign false
mkdir -p scripts
cp "$here/check-internal-ids.py" scripts/

dec="D-$(printf '%03d' 42)"
que="Q-$(printf '%03d' 7)"
fnd="SR-$(printf '%02d' 3)"
asg="M1-DO-$(printf '%d' 9)"
rg="RG-$(printf '%d' 10)"
inc="INC-$(printf '%03d' 1)"
short="m-$(printf '%d' 3)"
wpath="manage""ment/PLAN.md"
rel_wpath="../manage""ment/PLAN.md"
logpath="logs/code-""reviewer/x.txt"
legalpath="docs/le""gal/brief.md"
scratch="Scratch""Pad/x"
nbdash="D$(printf '\342\200\221')$(printf '%03d' 42)"
minus="Q$(printf '\342\210\222')$(printf '%03d' 7)"
risk="R-$(printf '%03d' 5)"
s2="S2-$(printf '%02d' 10)"
tm="TM-$(printf '%02d' 4)"
sect="SECT-$(printf '%02d' 2)"
iv="IV-$(printf '%02d' 1)"
rdy="RDY-TW-$(printf '%d' 1)"
dsc="DSC-CR-$(printf '%d' 1)"
pln="PLN-PO-$(printf '%d' 2)"
reportpath="reports/security-""engineer/x.md"
slpath="security-""local/x.txt"
wsfolder="face"" blur/x"

printf '// SPDX-License-Identifier: Apache-2.0\n// Covers FR-001, PRIV-004, ST-009 and DR-001 (ADR 0006).\nlet a = b[m-1]\n' > Ok.swift
git add . && git commit -q -m "clean"
expect IDs-requirement-ids-and-code-allowed 0 python3 -I scripts/check-internal-ids.py --tree

plant() { # plant <label> <value> : the value in a tracked note must fail the gate
    printf '# Note (%s)\n' "$2" > note.md
    git add note.md
    expect "IDs-planted-$1" 1 python3 -I scripts/check-internal-ids.py --tree
}
plant decision-number "$dec"
plant question-number "$que"
plant review-finding-label "$fnd"
plant assignment-label "$asg"
plant release-gate-item "$rg"
plant incident-number "$inc"
plant workspace-path "$wpath"
plant relative-workspace-path "$rel_wpath"
plant role-log-path "$logpath"
plant legal-docs-path "$legalpath"
plant scratch-folder "$scratch"
plant non-breaking-dash "$nbdash"
plant minus-sign "$minus"
plant risk-number "$risk"
plant review-series-label "$s2"
plant threat-model-label "$tm"
plant section-label "$sect"
plant input-verification-label "$iv"
plant readiness-label "$rdy"
plant discovery-label "$dsc"
plant plan-label "$pln"
plant role-report-path "$reportpath"
plant security-local-path "$slpath"
plant workspace-folder-name "$wsfolder"

printf '// SPDX-License-Identifier: Apache-2.0\nlet g = 1 // review %s\n' "$short" > note.swift
git add note.swift
expect IDs-short-label-in-comment 1 python3 -I scripts/check-internal-ids.py --files note.swift
git rm -q -f note.swift

# The gate's failure output names file, line, column and kind but never repeats the matched text.
printf '# Note (%s, %s, %s)\n' "$dec" "$wpath" "$fnd" > note.md
git add note.md
python3 -I scripts/check-internal-ids.py --tree > "$work/out.txt" 2>&1
got=$?
if [ "$got" -eq 1 ] && grep -qF "note.md:1: internal ID at column" "$work/out.txt" \
    && grep -qF "workspace path at column" "$work/out.txt" \
    && ! grep -qF -e "$dec" -e "$wpath" -e "$fnd" "$work/out.txt"; then
    pass=$((pass + 1)); echo "test-id-gate: IDs-output-never-repeats-match PASS"
else
    fail=$((fail + 1)); echo "test-id-gate: IDs-output-never-repeats-match FAIL (exit $got; output not shown, it may hold the probe)"
fi
git rm -q -f note.md

# File and directory NAMES are checked too, and a matching path is never printed (index + path hash instead).
plant_path() { # plant_path <label> <path> : a tracked file at that path (clean content) must fail the gate
    mkdir -p "$(dirname "$2")" && printf 'clean\n' > "$2"
    git add "$2"
    expect "IDs-planted-$1" 1 python3 -I scripts/check-internal-ids.py --tree
    git rm -q -f "$2"
}
plant_path id-in-file-name "notes-$dec.md"
plant_path id-in-directory-name "dir-$que/a.md"
plant_path workspace-folder-in-path "$slpath"
# Non-ASCII names are listed NUL-separated and opened as they are (a quoted name was skipped before).
cafe="caf$(printf '\303\251')"
printf '# Note (%s)\n' "$dec" > "$cafe-notes.md"
git add "$cafe-notes.md"
expect IDs-planted-id-in-non-ascii-named-file 1 python3 -I scripts/check-internal-ids.py --tree
git rm -q -f "$cafe-notes.md"
plant_path non-ascii-dash-in-file-name "notes-$nbdash.md"
plant_path non-ascii-name-and-id-in-name "$cafe-$dec.md"
# A listed file that cannot be read fails closed (exit 2), in both modes.
expect IDs-unreadable-listed-file-fails 2 python3 -I scripts/check-internal-ids.py --files no-such-file.md
printf 'clean\n' > gone.md && git add gone.md && rm -f gone.md
expect IDs-tracked-file-missing-fails 2 python3 -I scripts/check-internal-ids.py --tree
git rm -q --cached gone.md
printf 'clean\n' > "notes-$dec.md"
expect IDs-files-mode-id-in-file-name 1 python3 -I scripts/check-internal-ids.py --files "notes-$dec.md"
git add "notes-$dec.md"
python3 -I scripts/check-internal-ids.py --tree > "$work/out.txt" 2>&1
got=$?
if [ "$got" -eq 1 ] && grep -qF "internal ID in the path" "$work/out.txt" && grep -qF "(path SHA-256 " "$work/out.txt" \
    && ! grep -qF -e "$dec" -e "notes-" "$work/out.txt"; then
    pass=$((pass + 1)); echo "test-id-gate: IDs-path-never-repeated PASS"
else
    fail=$((fail + 1)); echo "test-id-gate: IDs-path-never-repeated FAIL (exit $got; output not shown, it may hold the probe)"
fi
git rm -q -f "notes-$dec.md"

# The column is that of the original line (two ligature characters before the probe expand under NFKC).
printf '%s%s %s\n' "$(printf '\357\254\201')" "$(printf '\357\254\201')" "$dec" > lig.md
python3 -I scripts/check-internal-ids.py --files lig.md > "$work/out.txt" 2>&1
if grep -qF "lig.md:1: internal ID at column 4" "$work/out.txt"; then
    pass=$((pass + 1)); echo "test-id-gate: IDs-column-of-original-line PASS"
else
    fail=$((fail + 1)); echo "test-id-gate: IDs-column-of-original-line FAIL"
fi
rm -f lig.md

# git error text quoting a revision argument is redacted.
python3 -I scripts/check-internal-ids.py --range "no-such-$dec..HEAD" > "$work/out.txt" 2>&1
got=$?
if [ "$got" -eq 2 ] && grep -qF "git rev-list failed" "$work/out.txt" && ! grep -qF "$dec" "$work/out.txt"; then
    pass=$((pass + 1)); echo "test-id-gate: IDs-git-error-redacted PASS"
else
    fail=$((fail + 1)); echo "test-id-gate: IDs-git-error-redacted FAIL (exit $got; output not shown, it may hold the probe)"
fi

printf 'feat: x\n\nRefs: ST-009, %s\n' "$dec" > "$work/msg"
expect IDs-commit-message-rejected 1 python3 -I scripts/check-internal-ids.py --message "$work/msg"
printf 'feat: x\n\nRefs: ST-009, PRIV-004\n' > "$work/msg"
expect IDs-commit-message-clean 0 python3 -I scripts/check-internal-ids.py --message "$work/msg"

range_base=$(git rev-parse HEAD)
echo r > r.txt && git add r.txt && git commit -q -m "clean change"
expect IDs-range-clean 0 python3 -I scripts/check-internal-ids.py --range "$range_base..HEAD"
echo s > s.txt && git add s.txt && git commit -q -m "change for $que"
expect IDs-range-rejects-message 1 python3 -I scripts/check-internal-ids.py --range "$range_base..HEAD"
git reset -q --hard "$range_base"

# Baseline: an empty baseline may not grow.
printf '# baseline\n' > scripts/internal-id-baseline.txt
git add . && git commit -q -m "empty baseline"
base=$(git rev-parse HEAD)
expect IDs-baseline-unchanged-passes 0 python3 -I scripts/check-internal-ids.py --baseline-shrinks-only "$base"
printf 'Legacy.swift\t%s\n' "0000000000000000000000000000000000000000000000000000000000000000" >> scripts/internal-id-baseline.txt
expect IDs-baseline-may-not-grow 1 python3 -I scripts/check-internal-ids.py --baseline-shrinks-only "$base"
git checkout -q -- scripts/internal-id-baseline.txt

# Hooks: the repository's own pre-commit and commit-msg hooks run the gate (data admission stubbed out here; it has
# its own tests in config/data-admission).
mkdir -p .githooks config/data-admission
cp "$here/../.githooks/pre-commit" "$here/../.githooks/commit-msg" .githooks/
printf '#!/bin/sh\n# SPDX-License-Identifier: Apache-2.0\nexit 0\n' > config/data-admission/check.sh
git add . && git commit -q -m "hooks"
git config core.hooksPath .githooks
printf '# Notes\nSee %s.\n' "$dec" > NOTES.md
git add NOTES.md
git commit -q -m "notes" > "$work/out.txt" 2>&1
got=$?
if [ "$got" -ne 0 ] && grep -qF "check-internal-ids: NOTES.md:2: internal ID at column" "$work/out.txt"; then
    pass=$((pass + 1)); echo "test-id-gate: Hook-pre-commit-runs-id-gate PASS (commit exit $got)"
else
    fail=$((fail + 1)); echo "test-id-gate: Hook-pre-commit-runs-id-gate FAIL (commit exit $got)"
fi
# Staged content counts, not the working copy.
printf '# Notes\nClean.\n' > NOTES.md
git commit -q -m "notes" > "$work/out.txt" 2>&1
got=$?
if [ "$got" -ne 0 ] && grep -qF "check-internal-ids: NOTES.md:2: internal ID at column" "$work/out.txt"; then
    pass=$((pass + 1)); echo "test-id-gate: Hook-checks-staged-not-working-copy PASS (commit exit $got)"
else
    fail=$((fail + 1)); echo "test-id-gate: Hook-checks-staged-not-working-copy FAIL (commit exit $got)"
fi
git reset -q && rm -f NOTES.md
# A staged file whose NAME carries an ID is rejected, and the name is not printed.
printf 'clean\n' > "notes-$dec.md"
git add "notes-$dec.md"
git commit -q -m "notes" > "$work/out.txt" 2>&1
got=$?
if [ "$got" -ne 0 ] && grep -qF "internal ID in the path" "$work/out.txt" && ! grep -qF "$dec" "$work/out.txt"; then
    pass=$((pass + 1)); echo "test-id-gate: Hook-pre-commit-checks-file-names PASS (commit exit $got)"
else
    fail=$((fail + 1)); echo "test-id-gate: Hook-pre-commit-checks-file-names FAIL (commit exit $got)"
fi
git reset -q && rm -f "notes-$dec.md"
# Non-ASCII staged file name: the content is checked, the clean file is committed.
cafe="caf$(printf '\303\251')"
printf '# Notes\nSee %s.\n' "$dec" > "$cafe.md"
git add "$cafe.md"
git commit -q -m "notes" > "$work/out.txt" 2>&1
got=$?
if [ "$got" -ne 0 ] && grep -qF "check-internal-ids: $cafe.md:2: internal ID at column" "$work/out.txt"; then
    pass=$((pass + 1)); echo "test-id-gate: Hook-non-ascii-name-id-rejected PASS (commit exit $got)"
else
    fail=$((fail + 1)); echo "test-id-gate: Hook-non-ascii-name-id-rejected FAIL (commit exit $got)"
fi
printf '# Notes\nClean.\n' > "$cafe.md"
git add "$cafe.md"
git commit -q -m "clean non-ascii notes" > "$work/out.txt" 2>&1
got=$?
if [ "$got" -eq 0 ]; then
    pass=$((pass + 1)); echo "test-id-gate: Hook-non-ascii-name-clean-passes PASS"
else
    fail=$((fail + 1)); echo "test-id-gate: Hook-non-ascii-name-clean-passes FAIL (commit exit $got)"
    sed 's/^/    /' "$work/out.txt" | head -8
fi
# File names with spaces: an ID in the content is rejected, clean content is committed.
printf '# Notes\nSee %s.\n' "$dec" > "my notes.md"
git add "my notes.md"
git commit -q -m "notes" > "$work/out.txt" 2>&1
got=$?
if [ "$got" -ne 0 ] && grep -qF "check-internal-ids: my notes.md:2: internal ID at column" "$work/out.txt"; then
    pass=$((pass + 1)); echo "test-id-gate: Hook-space-in-name-id-rejected PASS (commit exit $got)"
else
    fail=$((fail + 1)); echo "test-id-gate: Hook-space-in-name-id-rejected FAIL (commit exit $got)"
fi
printf '# Notes\nClean.\n' > "my notes.md"
git add "my notes.md"
git commit -q -m "clean notes" > "$work/out.txt" 2>&1
got=$?
if [ "$got" -eq 0 ]; then
    pass=$((pass + 1)); echo "test-id-gate: Hook-space-in-name-clean-passes PASS"
else
    fail=$((fail + 1)); echo "test-id-gate: Hook-space-in-name-clean-passes FAIL (commit exit $got)"
    sed 's/^/    /' "$work/out.txt" | head -8
fi
echo x > plain.txt && git add plain.txt
git commit -q -m "change for $dec" > "$work/out.txt" 2>&1
got=$?
if [ "$got" -ne 0 ] && grep -qF "check-internal-ids: commit message" "$work/out.txt"; then
    pass=$((pass + 1)); echo "test-id-gate: Hook-commit-msg-runs-id-gate PASS (commit exit $got)"
else
    fail=$((fail + 1)); echo "test-id-gate: Hook-commit-msg-runs-id-gate FAIL (commit exit $got)"
fi
git commit -q -m "clean change" > "$work/out.txt" 2>&1
expect_clean=$?
if [ "$expect_clean" -eq 0 ]; then
    pass=$((pass + 1)); echo "test-id-gate: Hook-clean-commit-passes PASS"
else
    fail=$((fail + 1)); echo "test-id-gate: Hook-clean-commit-passes FAIL (commit exit $expect_clean)"
    sed 's/^/    /' "$work/out.txt" | head -8
fi

echo "test-id-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
