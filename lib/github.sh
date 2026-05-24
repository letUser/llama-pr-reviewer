# GitHub fetchers: prior comments, reviews, active review threads.
# Sourced by bin/review-pr. Requires $FULL_REPO, $PR_NUMBER, $OWNER, $REPO,
# $SKIP_LOGINS_JQ, $MAX_COMMENT_BODY in scope.

# shellcheck shell=bash

fetch_inline_comments() {
  gh api "repos/$FULL_REPO/pulls/$PR_NUMBER/comments" --paginate \
    --jq "[.[] | select(($SKIP_LOGINS_JQ | index(.user.login // \"\")) == null)] \
          | map(\"- @\(.user.login) (\(.path):\(.line // .original_line // \"?\")): \\\"\(.body | gsub(\"\\n\"; \" \") | .[0:$MAX_COMMENT_BODY])\\\"\") \
          | .[]" 2>/dev/null || true
}

fetch_issue_comments() {
  gh api "repos/$FULL_REPO/issues/$PR_NUMBER/comments" --paginate \
    --jq "[.[] | select(($SKIP_LOGINS_JQ | index(.user.login // \"\")) == null)] \
          | map(\"- @\(.user.login): \\\"\(.body | gsub(\"\\n\"; \" \") | .[0:$MAX_COMMENT_BODY])\\\"\") \
          | .[]" 2>/dev/null || true
}

fetch_reviews() {
  gh api "repos/$FULL_REPO/pulls/$PR_NUMBER/reviews" --paginate \
    --jq "[.[] | select(($SKIP_LOGINS_JQ | index(.user.login // \"\")) == null)] \
          | map(\"- @\(.user.login) [\(.state)]: \\\"\(.body // \"\" | gsub(\"\\n\"; \" \") | .[0:$MAX_COMMENT_BODY])\\\"\") \
          | .[]" 2>/dev/null || true
}

# Active (unresolved, non-outdated) review threads only.
fetch_active_review_threads() {
  gh api graphql -F owner="$OWNER" -F repo="$REPO" -F number="$PR_NUMBER" -f query='
    query($owner:String!,$repo:String!,$number:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$number){
          reviewThreads(first:50){
            nodes{ isResolved isOutdated comments(first:5){ nodes{ author{login} path line body } } }
          }
        }
      }
    }' --jq "
      [.data.repository.pullRequest.reviewThreads.nodes[]
       | select(.isResolved == false and .isOutdated == false)
       | .comments.nodes[]
       | select(($SKIP_LOGINS_JQ | index(.author.login // \"\")) == null)
       | \"- @\(.author.login) (\(.path // \"?\"):\(.line // \"?\")): \\\"\(.body | gsub(\"\\n\"; \" \") | .[0:200])\\\"\"]
       | .[]" 2>/dev/null || true
}
