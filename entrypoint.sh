#!/usr/bin/env bash
set -o errexit
set -o pipefail

fail() {
  echo "$@" >&2
  exit 1
}

[ -n "${GITHUB_REPOSITORY}" ] || fail "No GITHUB_REPOSITORY was supplied."
[ -n "${PULL_REQUEST_LABEL}" ] || fail "No PULL_REQUEST_LABEL was supplied."
[ -n "${GITHUB_TOKEN}" ] || fail "No GITHUB_TOKEN was supplied."

# Determine https://github.com/OWNER/REPO from GITHUB_REPOSITORY.
REPO="${GITHUB_REPOSITORY##*/}"
OWNER="${GITHUB_REPOSITORY%/*}"

git config user.name "${GIT_AUTHOR_NAME}"
git config user.email "${GIT_AUTHOR_EMAIL}"

[ -n "${OWNER}" ] || fail "Could not determine GitHub owner from GITHUB_REPOSITORY."
[ -n "${REPO}" ] || fail "Could not determine GitHub repo from GITHUB_REPOSITORY."

# Fetch the PR titles, branch names, and SHAs from the pull requests that are marked with $PULL_REQUEST_LABEL.
pr_info=$(jq -cn '
    {
      query: $query,
      variables: {
        owner: $owner,
        repo: $repo,
        pull_request_label: $pull_request_label
      }
    }' \
    --arg query '
      query($owner: String!, $repo: String!, $pull_request_label: String!) {
        repository(owner: $owner, name: $repo) {
          pullRequests(states: OPEN, labels: [$pull_request_label], first: 100) {
            nodes {
              title
              headRefName
              headRefOid
            }
          }
        }
      }' \
    --arg owner "$OWNER" \
    --arg repo "$REPO" \
    --arg pull_request_label "$PULL_REQUEST_LABEL" |
    curl \
      --fail \
      --show-error \
      --silent \
      --header "Authorization: token $GITHUB_TOKEN" \
      --header "Content-Type: application/json" \
      --data @- \
      https://api.github.com/graphql)

# Extract the PR details using jq.
titles_and_branches=$(echo "$pr_info" | jq -r '
  .data.repository.pullRequests.nodes[] |
  "\(.title) (\(.headRefName)): \(.headRefOid)"
')

# Check if there are any results.
if [ -z "$titles_and_branches" ]; then
  echo "No pull requests with label $PULL_REQUEST_LABEL"
  exit 0
fi

# Print the details of each pull request.
echo "Found the following pull requests with label $PULL_REQUEST_LABEL:"
echo "$titles_and_branches"

# Extract SHAs for merging.
shas=$(echo "$pr_info" | jq -r '.data.repository.pullRequests.nodes[].headRefOid')

# Merge all SHAs together into one commit.
git fetch origin ${shas}
git merge --no-ff --no-commit ${shas}
git commit --message "Merged Pull Requests: $titles_and_branches"

echo "Merged ${#shas[@]} pull requests"
