#!/usr/bin/env bash
# Verify the target-project credential can do exactly what the workflow needs --
# and no more than it should.
#
#   ./verify-target-access.sh
#
# Run this before a planning run. A token missing one permission fails deep
# inside an agent turn, where it looks like a model error rather than a
# configuration one; this turns that into a clear failure up front.
#
# The token value is never printed, never logged, and never passed on a command
# line where it would appear in the process list.

set -uo pipefail
HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE_DIR/local.env" ] && . "$HERE_DIR/local.env"

pass=0; fail=0; warn=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }
caution() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; warn=$((warn+1)); }

TOKEN="${TARGET_REPO_TOKEN:-}"
REPO="${TARGET_REPO:-}"

echo
echo "CONFIGURATION"
[ -n "$REPO" ]  && ok "TARGET_REPO is set ($REPO)" || { bad "TARGET_REPO is not set in local.env"; exit 1; }
[ -n "$TOKEN" ] && ok "TARGET_REPO_TOKEN is set (${#TOKEN} chars)" || { bad "TARGET_REPO_TOKEN is not set in local.env"; exit 1; }

case "$TOKEN" in
  github_pat_*) KIND="fine-grained"; ok "token is fine-grained (github_pat_)" ;;
  ghp_*)        KIND="classic";      ok "token is a classic PAT (ghp_)" ;;
  gho_*|ghu_*)  KIND="oauth";     caution "this is an OAuth/user-to-server token, not a PAT" ;;
  *)            KIND="unknown";   caution "unrecognised token prefix - may be a legacy format" ;;
esac

# curl reads the header from a file descriptor rather than argv, so the value
# never appears in `ps`.
api() { # method path [body] -> "<http_code>\n<body>"
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -m 20 -w '\n%{http_code}' -X "$method"
              -H "Accept: application/vnd.github+json"
              -H @/dev/fd/3
              "https://api.github.com${path}")
  [ -n "$body" ] && args+=(-d "$body")
  curl "${args[@]}" 3<<<"Authorization: Bearer ${TOKEN}"
}
code_of() { printf '%s' "$1" | tail -1; }
body_of() { printf '%s' "$1" | sed '$d'; }

echo
echo "IDENTITY AND SCOPE"
r=$(api GET /rate_limit); c=$(code_of "$r")
[ "$c" = "200" ] && ok "token authenticates against the API" \
                 || { bad "authentication failed (HTTP $c) - token invalid, expired, or revoked"; exit 1; }

if [ "$KIND" = "classic" ]; then
  scopes=$(curl -s -m 20 -o /dev/null -D - -H @/dev/fd/3 https://api.github.com/rate_limit 3<<<"Authorization: Bearer ${TOKEN}" \
           | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')
  note "classic scopes: ${scopes:-<none>}"
  case "$scopes" in
    *repo*) ok "has 'repo' scope (covers issues, contents and pull requests)" ;;
    *)      bad "missing 'repo' scope - a classic token needs it for this workflow" ;;
  esac
  case "$scopes" in
    *gist*) caution "token carries 'gist' scope - an exfiltration channel a domain allowlist cannot see. Reissue without it." ;;
    *)      ok "no 'gist' scope" ;;
  esac
  case "$scopes" in
    *delete_repo*|*admin:org*) caution "token carries administrative scope far beyond this workflow" ;;
  esac
else
  note "fine-grained tokens do not advertise permissions on a header;"
  note "the checks below exercise them directly instead."
fi

echo
echo "READ ACCESS TO $REPO"
r=$(api GET "/repos/$REPO"); c=$(code_of "$r")
if [ "$c" = "200" ]; then
  ok "can read the repository"
  vis=$(body_of "$r" | python3 -c "import json,sys;print(json.load(sys.stdin).get('visibility','?'))" 2>/dev/null)
  note "visibility: $vis"
else
  bad "cannot read the repository (HTTP $c) - is the token scoped to it?"
fi

r=$(api GET "/repos/$REPO/labels?per_page=100"); c=$(code_of "$r")
if [ "$c" = "200" ]; then
  n=$(body_of "$r" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))" 2>/dev/null)
  ok "can list labels ($n present)"
  for required in spec status:backlog status:todo priority:1; do
    body_of "$r" | grep -q "\"name\": *\"$required\"" \
      && ok "label exists: $required" \
      || bad "label missing: $required - run ./bootstrap-labels.sh"
  done
else
  bad "cannot list labels (HTTP $c)"
fi

echo
echo "WRITE ACCESS  (creates a probe issue, then closes it)"
probe=$(api POST "/repos/$REPO/issues" \
  '{"title":"access probe - safe to close","body":"Written by verify-target-access.sh to confirm the credential can create issues. Closed automatically."}')
c=$(code_of "$probe")
if [ "$c" = "201" ]; then
  num=$(body_of "$probe" | python3 -c "import json,sys;print(json.load(sys.stdin)['number'])" 2>/dev/null)
  ok "can CREATE issues (opened #$num)"

  r=$(api POST "/repos/$REPO/issues/$num/labels" '{"labels":["status:backlog","priority:4"]}')
  [ "$(code_of "$r")" = "200" ] && ok "can APPLY labels" || bad "cannot apply labels (HTTP $(code_of "$r"))"

  r=$(api POST "/repos/$REPO/issues/$num/comments" '{"body":"Claim-comment mechanism check."}')
  [ "$(code_of "$r")" = "201" ] && ok "can COMMENT (the dispatcher claims tickets this way)" \
                                || bad "cannot comment (HTTP $(code_of "$r"))"

  r=$(api PATCH "/repos/$REPO/issues/$num" '{"state":"closed"}')
  [ "$(code_of "$r")" = "200" ] && ok "can CLOSE issues (probe #$num cleaned up)" \
                                || caution "could not close probe #$num - close it by hand"
else
  bad "cannot create issues (HTTP $c) - the planner cannot work without this"
  note "$(body_of "$probe" | head -c 200)"
fi

echo
echo "CONTENTS AND PULL REQUESTS  (workers need these; read-only probes)"
r=$(api GET "/repos/$REPO/contents/README.md"); c=$(code_of "$r")
[ "$c" = "200" ] && ok "can read repository contents" || bad "cannot read contents (HTTP $c)"

r=$(api GET "/repos/$REPO/pulls?state=all&per_page=1"); c=$(code_of "$r")
[ "$c" = "200" ] && ok "can list pull requests" || bad "cannot list pull requests (HTTP $c)"

note "push and PR creation are only truly proven by a worker doing them;"
note "a token that can read contents and list PRs usually can, but not always."

echo
printf 'RESULT: %d passed, %d failed, %d warnings\n\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ] || exit 1
