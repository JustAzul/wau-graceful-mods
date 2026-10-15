#!/usr/bin/env bash
# Tests for scripts/pii-scan.sh. Plain bash, no framework.
# usage: scripts/tests/pii-scan.test.sh   (exit 0 when every case passes)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scan="$here/../pii-scan.sh"
failed=0
passed=0
dirs=()

cleanup() {
    local d
    for d in "${dirs[@]}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

new_repo() {
    local d
    d="$(mktemp -d)"
    dirs+=("$d")
    git -C "$d" init -q -b main
    git -C "$d" config user.name "tester"
    git -C "$d" config user.email "1+tester@users.noreply.github.com"
    printf '%s\n' "$d"
}

# check <name> <expected exit> <repo> [env assignments...]
check() {
    local name="$1" expected="$2" repo="$3"
    shift 3
    local out code
    out="$(env "$@" "$scan" "$repo" 2>&1)"
    code=$?
    if [ "$code" -eq "$expected" ]; then
        passed=$((passed + 1))
        printf 'ok   %s\n' "$name"
    else
        failed=$((failed + 1))
        printf 'FAIL %s (exit %s, wanted %s)\n%s\n' "$name" "$code" "$expected" "$out"
    fi
}

# --- clean repository
r="$(new_repo)"
printf 'Plain text about a tool.\n' > "$r/README.md"
git -C "$r" add README.md && git -C "$r" commit -qm "init"
check "clean repo passes" 0 "$r"

# Fixtures are assembled at run time so this file does not look like PII to the scanner.
at='@'
slash='/'

# --- e-mail addresses
r="$(new_repo)"; printf 'write to someone%sgmail.com\n' "$at" > "$r/a.md"
check "personal e-mail is flagged" 1 "$r"
r="$(new_repo)"; printf 'mail user%sexample.com or 1+x%susers.noreply.github.com\n' "$at" "$at" > "$r/a.md"
check "example and noreply e-mails are allowed" 0 "$r"

# --- user paths
r="$(new_repo)"; printf 'C:\\Users\\someone\\AppData\\Local\n' > "$r/a.md"
check "Windows user path is flagged" 1 "$r"
r="$(new_repo)"; printf 'C:\\Users\\fake-user\\x and C:\\Users\\<user>\\y\n' > "$r/a.md"
check "placeholder Windows user paths are allowed" 0 "$r"
r="$(new_repo)"; printf '%shome%ssomeone%sprojects\n' "$slash" "$slash" "$slash" > "$r/a.md"
check "Linux home path is flagged" 1 "$r"
r="$(new_repo)"; printf '%shome%sfake-user%sx\n' "$slash" "$slash" "$slash" > "$r/a.md"
check "placeholder Linux home path is allowed" 0 "$r"
r="$(new_repo)"; printf '%shome%sfake-user and %shome%ssomeone\n' "$slash" "$slash" "$slash" "$slash" > "$r/a.md"
check "allowed and real paths on one line are still flagged" 1 "$r"
r="$(new_repo)"; printf '%smnt%sc%sUsers%ssomeone%sAppData\n' "$slash" "$slash" "$slash" "$slash" "$slash" > "$r/a.md"
check "WSL user path is flagged" 1 "$r"

# --- addresses
r="$(new_repo)"; printf 'router at %s.%s.%s.%s\n' 192 168 1 10 > "$r/a.md"
check "IPv4 address is flagged" 1 "$r"
r="$(new_repo)"; printf 'loopback 127.0.0.1 and version 10.4.5674.0\n' > "$r/a.md"
check "loopback and four-part versions are allowed" 0 "$r"

# --- secrets
r="$(new_repo)"; printf 'token ghp_%s\n' "$(printf 'a%.0s' $(seq 1 36))" > "$r/a.md"
check "GitHub token shape is flagged" 1 "$r"

# --- external denylist
r="$(new_repo)"; printf 'Zebra-Corp internal\n' > "$r/a.md"
deny="$(mktemp)"; dirs+=("$deny"); printf 'zebra-corp\n' > "$deny"
check "denylist pattern is flagged case-insensitively" 1 "$r" "PII_DENYLIST_FILE=$deny"
check "no denylist, no finding" 0 "$r" "PII_DENYLIST_FILE=/nonexistent/denylist"

# --- commit metadata
r="$(new_repo)"; printf 'x\n' > "$r/a.md"
git -C "$r" add a.md
git -C "$r" -c user.email="real.person${at}gmail.com" commit -qm "init"
check "non-noreply commit e-mail is flagged" 1 "$r"

# --- ignored files are not scanned
r="$(new_repo)"; printf 'x\n' > "$r/a.md"; printf '*.log\n' > "$r/.gitignore"; printf 'someone%sgmail.com\n' "$at" > "$r/b.log"
check "ignored files are skipped" 0 "$r"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
