#!/usr/bin/env bash
# Unit tests for pure helper functions extracted from the shell scripts.
# No SSH/network needed: functions are pulled out by name with awk.
# Run: bash tests/test_shell_helpers.sh
set -uo pipefail
cd "$(dirname "$0")/.."

FAILS=0

# extract_fn <file> <funcname> — print a top-level function definition
extract_fn() {
    awk -v fn="$2()" '
        index($0, fn) == 1 { print; inbody = 1; next }
        inbody && /^}/ { print; exit }
        inbody { print }
    ' "$1"
}

assert_eq() { # assert_eq <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1: expected [$2], got [$3]"
        FAILS=$((FAILS + 1))
    fi
}

# --- sub_vless.sh: mk_safe -------------------------------------------------
eval "$(extract_fn sub_vless.sh mk_safe)"

assert_eq "mk_safe lowercases"                    "vasya"                    "$(mk_safe 'Vasya')"
assert_eq "mk_safe keeps allowed chars"           "artem_mirea"              "$(mk_safe 'artem_mirea')"
assert_eq "mk_safe replaces bad chars"            "me_vasya"                 "$(mk_safe 'Me Vasya')"
assert_eq "mk_safe pads names shorter than 3"     "a_x"                      "$(mk_safe 'a')"
assert_eq "mk_safe pads empty name"               "_x_x"                     "$(mk_safe '')"
# regression: 36-char name without trailing underscore used to hang forever
LONG_OUT="$(mk_safe 'friend_alexey_from_school_classmates')"
assert_eq "mk_safe long name is trimmed, no hang" \
    "$(printf '%s' 'friend_alexey_from_school_classmates' | cut -c1-30)" \
    "$LONG_OUT"
assert_eq "mk_safe result length capped at 30"    "30"                       "${#LONG_OUT}"
assert_eq "mk_safe stays under Marzban 32 limit"  "yes" \
    "$([[ ${#LONG_OUT} -le 32 ]] && echo yes || echo no)"

# --- sq() shell-quoting (same helper in every script) -----------------------
eval "$(extract_fn sub.sh sq)"

assert_eq "sq plain word"        "'hello'"      "$(sq 'hello')"
assert_eq "sq with spaces"       "'a b c'"      "$(sq 'a b c')"
assert_eq "sq escapes quote"     "'it'\\''s'"   "$(sq "it's")"
assert_eq "sq empty string"      "''"           "$(sq '')"

# round-trip through eval proves the quoting is safe to embed
V="it's a 'quoted' value"
eval "RT=$(sq "$V")"
assert_eq "sq round-trips through eval" "$V" "$RT"

if [[ "$FAILS" -eq 0 ]]; then
    echo "shell helpers: all tests passed"
    exit 0
fi
echo "shell helpers: $FAILS test(s) failed"
exit 1
