#!/bin/bash
# Test suite for rmt. Creates small temp files and trashes them
# (they end up in your Trash; empty it afterwards if you care).
set -u

RMT="$(cd "$(dirname "$0")" && pwd)/rmt"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/rmt-test.XXXXXX")"
cd "$SANDBOX" || exit 1

pass=0 fail=0
ok()   { pass=$((pass+1)); echo "  ok: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
check() { # check <desc> <condition...>
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}

echo "== basic =="
touch a.txt
"$RMT" a.txt </dev/null
check "trash a file"                 test ! -e a.txt
check "exit 0 on success"            test $? -eq 0

"$RMT" nope.txt </dev/null 2>err.out; rc=$?
check "missing file exits 1"         test $rc -eq 1
check "missing file message"         grep -q "No such file" err.out

"$RMT" -f nope.txt </dev/null 2>err.out; rc=$?
check "-f missing file exits 0"      test $rc -eq 0
check "-f missing file is silent"    test ! -s err.out

echo "== directories =="
mkdir dir1 && touch dir1/x
"$RMT" dir1 </dev/null 2>err.out; rc=$?
check "dir without -r exits 1"       test $rc -eq 1
check "dir without -r message"       grep -q "is a directory" err.out
check "dir without -r kept"          test -d dir1

"$RMT" -r dir1 </dev/null
check "-r trashes dir"               test ! -e dir1

mkdir empty
"$RMT" -d empty </dev/null
check "-d trashes empty dir"         test ! -e empty

mkdir full && touch full/x
"$RMT" -d full </dev/null 2>err.out; rc=$?
check "-d non-empty exits 1"         test $rc -eq 1
check "-d non-empty message"         grep -q "Directory not empty" err.out
"$RMT" -rf full

echo "== flags =="
touch v.txt
out=$("$RMT" -v v.txt </dev/null)
check "-v prints path"               test "$out" = "v.txt"

touch -- -dash.txt
"$RMT" -- -dash.txt </dev/null
check "-- stops flag parsing"        test ! -e ./-dash.txt

touch combo.txt; mkdir combod
"$RMT" -rfv combo.txt combod </dev/null >/dev/null
check "combined -rfv works"          test ! -e combo.txt -a ! -e combod

"$RMT" 2>err.out; rc=$?
check "no args exits 1"              test $rc -eq 1
check "no args prints usage"         grep -q "usage" err.out

"$RMT" -f; rc=$?
check "-f with no args exits 0"      test $rc -eq 0

touch p.txt
"$RMT" -P p.txt </dev/null
check "-P accepted (no-op)"          test ! -e p.txt

mkdir xdir && touch xdir/f
"$RMT" -rx xdir </dev/null
check "-x accepted"                  test ! -e xdir

"$RMT" -W w.txt 2>err.out; rc=$?
check "-W exits 1 (no union mounts)" test $rc -eq 1

"$RMT" -q 2>err.out; rc=$?
check "unknown flag exits 1"         test $rc -eq 1

echo "== prompts =="
touch i.txt
echo n | "$RMT" -i i.txt 2>/dev/null
check "-i answered n keeps file"     test -e i.txt
echo y | "$RMT" -i i.txt 2>/dev/null
check "-i answered y trashes file"   test ! -e i.txt

touch f1 f2 f3 f4
echo n | "$RMT" -I f1 f2 f3 f4 2>/dev/null; rc=$?
check "-I >3 files answered n"       test -e f1 -a $rc -eq 1
echo y | "$RMT" -I f1 f2 f3 f4 2>/dev/null
check "-I >3 files answered y"       test ! -e f1 -a ! -e f4

mkdir Idir
echo y | "$RMT" -Ir Idir 2>/dev/null
check "-I recursive answered y"      test ! -e Idir

touch fi.txt
echo y | "$RMT" -fi fi.txt 2>/dev/null
check "later -i overrides -f"        test ! -e fi.txt

echo "== safety rails =="
"$RMT" -rf . 2>err.out; rc=$?
check "refuses \".\""                test $rc -eq 1
check "\".\" message"                grep -q 'may not be removed' err.out
"$RMT" -rf / 2>err.out; rc=$?
check "refuses \"/\""                test $rc -eq 1

echo "== trash protection =="
"$RMT" -rf "$HOME/.Trash" 2>err.out; rc=$?
check "refuses ~/.Trash"             test $rc -eq 1
check "~/.Trash message"             grep -q "refusing to remove the Trash" err.out
check "~/.Trash still exists"        test -d "$HOME/.Trash"

inmark="rmt-intrash-$$.txt"
touch "$inmark" && "$RMT" "$inmark" </dev/null
"$RMT" "$HOME/.Trash/$inmark" 2>err.out; rc=$?
check "refuses file inside Trash"    test $rc -eq 1
check "inside-Trash message"         grep -q "already in the Trash" err.out
check "file kept in Trash"           test -e "$HOME/.Trash/$inmark"

ln -s "$HOME/.Trash" trashlink
"$RMT" trashlink </dev/null; rc=$?
check "symlink TO Trash is trashed"  test ! -L trashlink -a $rc -eq 0
check "Trash survives symlink trash" test -d "$HOME/.Trash"

mkdir -p fake/.Trashes && touch fake/.Trashes/x
"$RMT" -rf fake/.Trashes </dev/null; rc=$?
check "non-mount .Trashes trashable" test ! -e fake/.Trashes -a $rc -eq 0
"$RMT" -rf fake

if [ -d /.Trashes ]; then
  "$RMT" -rf /.Trashes 2>/dev/null; rc=$?
  check "volume /.Trashes not removed" test $rc -eq 1 -a -d /.Trashes
fi

echo "== symlinks =="
touch target.txt && ln -s target.txt link
"$RMT" link </dev/null
check "symlink itself trashed"       test ! -L link
check "symlink target survives"      test -e target.txt
"$RMT" -f target.txt

ln -s /nonexistent broken
"$RMT" broken </dev/null; rc=$?
check "broken symlink trashed"       test ! -L broken -a $rc -eq 0

echo "== odd names =="
touch "spa ce.txt" $'new\nline.txt'
"$RMT" "spa ce.txt" $'new\nline.txt' </dev/null
check "space in name"                test ! -e "spa ce.txt"
check "newline in name"              test ! -e $'new\nline.txt'

echo "== recoverability =="
marker="rmt-recover-$$.txt"
echo "hello" > "$marker"
"$RMT" "$marker" </dev/null
check "file landed in Trash"         test -e "$HOME/.Trash/$marker"
check "content intact in Trash"      grep -q hello "$HOME/.Trash/$marker"

echo "== exit code aggregation =="
touch good.txt
"$RMT" good.txt nope.txt 2>/dev/null; rc=$?
check "partial failure exits 1"      test $rc -eq 1
check "good operand still trashed"   test ! -e good.txt

cd / && command rm -rf "$SANDBOX"
echo
echo "$pass passed, $fail failed"
exit $((fail > 0))
