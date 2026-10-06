#!/usr/bin/env bash
# Fetch and project human-resolved review threads for the review pre-script.
# The fullsend CLI owns forge-specific fetching; this script owns the agent
# input format and filtering policy.
set -euo pipefail

OUTPUT_FILE="${HUMAN_RESOLVED_FILE:-${GITHUB_WORKSPACE:-/tmp}/human-resolved-threads.json}"
mkdir -p "$(dirname "${OUTPUT_FILE}")"

write_empty() {
  local reason="$1"
  printf '%s\n' "{\"resolved_threads\":[],\"metadata\":{\"error\":\"${reason}\"}}" > "${OUTPUT_FILE}"
}

if [[ "${GITHUB_ACTIONS:-}" != "true" && "${GITLAB_CI:-}" != "true" ]]; then
  write_empty "not_ci"
  exit 0
fi

ORG_NAME="${REPO%%/*}"
REVIEW_BOT="${ORG_NAME}-review[bot]"
SHARED_REVIEW_BOT="fullsend-ai-review[bot]"
REVIEW_BOT_LOGIN="${ORG_NAME}-review"
SHARED_REVIEW_BOT_LOGIN="fullsend-ai-review"
APP_SET_REVIEW_BOT=""
APP_SET_REVIEW_BOT_LOGIN=""
if [[ -n "${FULLSEND_APP_SET:-}" ]]; then
  APP_SET_REVIEW_BOT="${FULLSEND_APP_SET}-review[bot]"
  APP_SET_REVIEW_BOT_LOGIN="${FULLSEND_APP_SET}-review"
fi

fetch_args=(fetch-review-threads --forge "${FULLSEND_FORGE}" --repo "${REPO}" --pr "${PR_NUMBER}")
if [[ "${FULLSEND_FORGE}" == "gitlab" && -n "${CI_SERVER_URL:-}" ]]; then
  fetch_args+=(--base-url "${CI_SERVER_URL}")
fi

if ! response="$(GH_TOKEN="${REVIEW_TOKEN:-${GH_TOKEN:-}}" \
  GITLAB_TOKEN="${REVIEW_TOKEN:-${GITLAB_TOKEN:-}}" \
  fullsend "${fetch_args[@]}" 2>/dev/null)"; then
  echo "::warning::Failed to fetch review threads; continuing without human-resolution data"
  write_empty "fetch_failed"
  exit 0
fi

nodes_json="$(jq -c '.threads // []' <<<"${response}" 2>/dev/null)" || {
  write_empty "parse_failed"
  exit 0
}
truncated="$(jq -r '.truncated // false' <<<"${response}" 2>/dev/null || printf 'false')"

resolved_threads="$(jq -c \
  --arg bot "${REVIEW_BOT}" \
  --arg shared_bot "${SHARED_REVIEW_BOT}" \
  --arg bot_login "${REVIEW_BOT_LOGIN}" \
  --arg shared_bot_login "${SHARED_REVIEW_BOT_LOGIN}" \
  --arg app_set_bot "${APP_SET_REVIEW_BOT}" \
  --arg app_set_bot_login "${APP_SET_REVIEW_BOT_LOGIN}" \
  '[.[]
    | select(.is_resolved == true)
    | select(.resolved_by != null and .resolved_by != "")
    | select(.resolved_by_type == "User")
    | select(.resolved_by != $bot and .resolved_by != $shared_bot)
    | select(.resolved_by != $bot_login and .resolved_by != $shared_bot_login)
    | select(.resolved_by != $app_set_bot and .resolved_by != $app_set_bot_login)
    | select((.resolved_by | endswith("[bot]")) | not)
    | select((.comments // [] | length) > 0)
    | select((.comments_truncated // false) == false)
    | select(any(.comments[];
        .author_type == "Bot" and
        (.author == $bot_login or .author == $shared_bot_login or
         .author == $app_set_bot_login or .author == $bot or
         .author == $shared_bot or .author == $app_set_bot)))
    | .resolved_by as $resolver
    | {
        file: .path,
        line: .line,
        original_line: .original_line,
        resolved_by: $resolver,
        bot_finding_snippet: (
          [.comments[] | select(.author_type == "Bot")
           | select(.author == $bot_login or .author == $shared_bot_login or
                    .author == $app_set_bot_login or .author == $bot or
                    .author == $shared_bot or .author == $app_set_bot)]
          | first // null | if . then (.body | .[0:200]) else null end
        ),
        finding_id: (
          [.comments[] | select(.author_type == "Bot")
           | select(.author == $bot_login or .author == $shared_bot_login or
                    .author == $app_set_bot_login or .author == $bot or
                    .author == $shared_bot or .author == $app_set_bot)]
          | first // null
          | if . then (.body | capture("<!-- finding:(?<id>[a-zA-Z0-9_]+) -->") // null | .id // null) else null end
        ),
        human_response: ([.comments[] | select(.author == $resolver)] | last // null
          | if . then (.body | .[0:500]) else null end),
        resolution_context: (if ([.comments[] | select(.author == $resolver)] | length) > 0
          then "explicit_dismissal" else "silent_resolution" end)
      }
  ]' <<<"${nodes_json}" 2>/dev/null)" || resolved_threads='[]'

jq -n \
  --argjson threads "${resolved_threads}" \
  --argjson pr_num "${PR_NUMBER}" \
  --arg repo "${REPO}" \
  --argjson thread_count "$(jq 'length' <<<"${nodes_json}")" \
  --argjson resolved_count "$(jq 'length' <<<"${resolved_threads}")" \
  --argjson truncated "${truncated}" \
  --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{resolved_threads: $threads, metadata: {pr_number: $pr_num, repo: $repo,
    thread_count: $thread_count, human_resolved_count: $resolved_count,
    truncated: $truncated, fetched_at: $fetched_at}}' > "${OUTPUT_FILE}" || {
  echo "::warning::Failed to write human-resolution data; continuing without it"
  write_empty "write_failed"
}
