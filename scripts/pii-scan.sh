#!/usr/bin/env bash
# PII scan for a repository before it is published.
#
# usage: scripts/pii-scan.sh [repo-dir]
#
# Scans every tracked and untracked-but-not-ignored text file, and the author and
# committer e-mails of all commits. Extra patterns (one extended regex per line,
# matched case-insensitively) come from the file named by $PII_DENYLIST_FILE, or
# ~/.config/wau-graceful-mods/pii-denylist.txt when that is unset. Keep that file
# outside the repository: it holds the very identifiers being kept out.
#
# Output names the finding and its location, never the matched text, so a secret
# that is found does not get copied into logs.
#
# Exit: 0 clean, 1 findings, 2 usage or environment error.
set -uo pipefail

repo="${1:-.}"
cd "$repo" || { echo "cannot enter $repo" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository: $repo" >&2; exit 2; }

findings=0
files=()
while IFS= read -r -d '' f; do
    files+=("$f")
done < <(git ls-files -co --exclude-standard -z)

if [ "${#files[@]}" -eq 0 ]; then
    echo "no files to scan" >&2
    exit 2
fi

# report <label> <file> <line number>
report() {
    printf 'FINDING %s at %s:%s\n' "$1" "$2" "$3"
    findings=$((findings + 1))
}

# scan <label> <pattern> [allow pattern] [grep case flag]
scan() {
    local label="$1" pattern="$2" allow="${3:-}" icase="${4:-}" f hit n text
    local flags=(-nIE) qflags=(-qE)
    if [ -n "$icase" ]; then
        flags+=("$icase")
        qflags+=("$icase")
    fi
    for f in "${files[@]}"; do
        [ -f "$f" ] || continue
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            n="${hit%%:*}"
            text="${hit#*:}"
            if [ -n "$allow" ] && printf '%s\n' "$text" | grep -qE -- "$allow"; then
                # allowed examples may share a line with a real finding, so re-check
                # the line with the allowed matches removed ('#' cannot occur in a pattern here)
                text="$(printf '%s\n' "$text" | sed -E "s#(${allow})##g")"
                printf '%s\n' "$text" | grep "${qflags[@]}" -- "$pattern" || continue
            fi
            report "$label" "$f" "$n"
        done < <(grep "${flags[@]}" -- "$pattern" "$f" 2>/dev/null)
    done
}

octet='(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})'

scan "email" '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+' \
    '[A-Za-z0-9._%+-]+@(users\.noreply\.github\.com|example\.(com|org|net))'
scan "windows-user-path" '[A-Za-z]:\\Users\\[^\\ <%$"]+' \
    '[A-Za-z]:\\Users\\(fake-user|Public|Default|All Users)'
scan "linux-home-path" '/home/[A-Za-z0-9._-]+' '/home/fake-user'
scan "wsl-user-path" '/mnt/[a-z]/Users/[^/ <"]+' '/mnt/[a-z]/Users/(fake-user|Public|Default)'
scan "ipv4" "\\b${octet}(\\.${octet}){3}\\b" '\b(127\.0\.0\.1|0\.0\.0\.0)\b'
scan "token" 'gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{32,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

denylist="${PII_DENYLIST_FILE:-$HOME/.config/wau-graceful-mods/pii-denylist.txt}"
if [ -f "$denylist" ]; then
    while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue
        case "$pattern" in '#'*) continue ;; esac
        scan "denylist" "$pattern" "" "-i"
    done < "$denylist"
fi

# commit metadata: every author and committer e-mail must be a GitHub noreply address
if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    while IFS= read -r mail; do
        [ -n "$mail" ] || continue
        case "$mail" in
            *@users.noreply.github.com) ;;
            *) printf 'FINDING commit-email at git history\n'; findings=$((findings + 1)) ;;
        esac
    done < <(git log --format='%ae%n%ce' | sort -u)
fi

if [ "$findings" -gt 0 ]; then
    printf '%s finding(s)\n' "$findings"
    exit 1
fi
printf 'clean\n'
exit 0
