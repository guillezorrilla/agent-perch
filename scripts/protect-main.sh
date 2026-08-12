#!/bin/zsh -e
# Applies the branch ruleset that protects `main`.
#
# Rulesets are a PAID feature on private repositories — GitHub answers this
# request with "Upgrade to GitHub Pro or make this repository public". They are
# FREE on public repos, so run this the moment the repo goes public.
#
#   ./scripts/protect-main.sh
#
# Re-running updates the existing ruleset instead of creating a second one.

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
NAME="main"

read -r -d '' RULES <<'JSON' || true
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash", "merge", "rebase"]
      }
    }
  ]
}
JSON

existing="$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$NAME\") | .id" 2>/dev/null | head -1)"

if [[ -n "$existing" ]]; then
  print "Updating ruleset $existing on $REPO"
  print -r -- "$RULES" | gh api -X PUT "repos/$REPO/rulesets/$existing" --input - > /dev/null
else
  print "Creating ruleset on $REPO"
  print -r -- "$RULES" | gh api -X POST "repos/$REPO/rulesets" --input - > /dev/null
fi

print "Done. main now requires a pull request; force-pushes and deletion are blocked."
print ""
print "Notes:"
print "  • 1 approval required, with repository-admin bypass. Anyone else's PR needs"
print "    your review; your own do not, because GitHub will not let you approve your"
print "    own PR and without the bypass you would be locked out of your own repo."
print "  • While you are the only account with write access the approval rule is"
print "    largely symbolic — outside contributors fork and cannot merge regardless."
print "    It starts doing real work the moment a second collaborator is added."
print "  • Stale reviews are dismissed on push, so an approval cannot survive a"
print "    rewrite of the code it approved."
print "  • Add a required status check once CI has run at least once on the default"
print "    branch, otherwise the check name will not exist yet to select."
