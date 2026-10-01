#!/usr/bin/env bash
# Long-lived poll loop: fetch every INTERVAL_S seconds, commit+push on change,
# dispatch a successor run shortly before the 6h job limit, then exit.
set -uo pipefail
intervalS=${INTERVAL_S:-600}
handoffMin=${HANDOFF_MIN:-335}
maxFails=${MAX_FAILS:-6}
branch=${GITHUB_REF_NAME:-main}
repo=${GITHUB_REPOSITORY:-}
wf=${WORKFLOW_FILE:-watch.yml}
squash=${SQUASH:-1}
botEmail="github-actions[bot]@users.noreply.github.com"
git config user.name "github-actions[bot]"
git config user.email "$botEmail"
start=$(date +%s)
handoffAt=$(( handoffMin * 60 ))
fails=0
pushChanges() {
  git add -A data COMPETITIONS.md
  if ! git diff --cached --quiet; then
    git commit -q -m "data: kaggle competitions $(date -u +'%F %H:%MZ')"
  fi
  if [ "$(git rev-list --count "origin/$branch..HEAD")" -eq 0 ]; then
    return 0
  fi
  for i in 1 2 3; do
    if git fetch -q origin "$branch" && git rebase -q --autostash -X theirs "origin/$branch" && git push -q origin "HEAD:$branch"; then
      echo "pushed $(git rev-parse --short HEAD)"
      return 0
    fi
    git rebase --abort 2>/dev/null || true
    sleep 5
  done
  echo "::warning::push failed, will retry next tick"
  return 1
}
# Runs once at the start of every generation (SQUASH=1): rewrite $branch so it
# holds only non-bot commits (trees, authors, dates, messages preserved; SHAs
# preserved when nothing bot-made sits below them) plus one bot snapshot of the
# current tree. All bot data commits disappear. --force-with-lease makes it a
# no-op if anyone pushed in the meantime. Safe because this job is the only
# writer while it runs (concurrency group).
squashHistory() {
  if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    git fetch -q --unshallow origin "$branch" || return 1
  else
    git fetch -q origin "$branch" || return 1
  fi
  remoteSha=$(git rev-parse "origin/$branch")
  botN=0
  parent=""
  for c in $(git rev-list --reverse --first-parent "origin/$branch"); do
    mapfile -t meta < <(git log -1 --format='%an%n%ae%n%aD%n%cn%n%ce%n%cD' "$c")
    if [ "${meta[1]}" = "$botEmail" ]; then
      botN=$(( botN + 1 ))
      continue
    fi
    tree=$(git rev-parse "$c^{tree}")
    if [ -n "$parent" ]; then
      newC=$(printf '%s\n' "$(git log -1 --format=%B "$c")" | GIT_AUTHOR_NAME="${meta[0]}" GIT_AUTHOR_EMAIL="${meta[1]}" GIT_AUTHOR_DATE="${meta[2]}" GIT_COMMITTER_NAME="${meta[3]}" GIT_COMMITTER_EMAIL="${meta[4]}" GIT_COMMITTER_DATE="${meta[5]}" git commit-tree "$tree" -p "$parent" -F -)
    else
      newC=$(printf '%s\n' "$(git log -1 --format=%B "$c")" | GIT_AUTHOR_NAME="${meta[0]}" GIT_AUTHOR_EMAIL="${meta[1]}" GIT_AUTHOR_DATE="${meta[2]}" GIT_COMMITTER_NAME="${meta[3]}" GIT_COMMITTER_EMAIL="${meta[4]}" GIT_COMMITTER_DATE="${meta[5]}" git commit-tree "$tree" -F -)
    fi
    parent=$newC
  done
  if [ "$botN" -le 1 ]; then
    echo "squash: $botN bot commits on $branch, nothing to do"
    return 0
  fi
  tree=$(git rev-parse "origin/$branch^{tree}")
  if [ -n "$parent" ] && [ "$(git rev-parse "$parent^{tree}")" = "$tree" ]; then
    newSha=$parent
  elif [ -n "$parent" ]; then
    newSha=$(git commit-tree "$tree" -p "$parent" -m "data: snapshot $(date -u +'%F %H:%MZ'), squashed $botN bot commits")
  else
    newSha=$(git commit-tree "$tree" -m "data: snapshot $(date -u +'%F %H:%MZ'), squashed $botN bot commits")
  fi
  if git push -q --force-with-lease="refs/heads/$branch:$remoteSha" origin "$newSha:refs/heads/$branch"; then
    git update-ref "refs/remotes/origin/$branch" "$newSha"
    git reset -q --hard "$newSha"
    echo "squash: removed $botN bot commits, $branch is now $newSha"
  else
    echo "::warning::squash: push rejected ($branch moved during rewrite), skipped this time"
    return 1
  fi
}
handoff() {
  echo "handoff at $(( $(date +%s) - start ))s"
  pushChanges || true
  echo "dispatching successor run"
  if gh workflow run "$wf" --repo "$repo" --ref "$branch"; then
    echo "successor dispatched, exiting"
  else
    echo "::warning::handoff dispatch failed, tick.yml restarts the watcher within 5 min"
  fi
}
if [ "$squash" = "1" ]; then
  squashHistory || true
fi
while true; do
  tickStart=$(date +%s)
  if [ $(( tickStart - start )) -ge "$handoffAt" ]; then
    handoff
    exit 0
  fi
  if python3 watch.py; then
    fails=0
    pushChanges || true
  else
    fails=$(( fails + 1 ))
    echo "::warning::watch.py failed ($fails/$maxFails in a row)"
    if [ "$fails" -ge "$maxFails" ]; then
      echo "::error::$maxFails consecutive failures, exiting red; tick.yml restarts the watcher"
      exit 1
    fi
  fi
  now=$(date +%s)
  sleepFor=$(( intervalS - (now - tickStart) ))
  untilHandoff=$(( start + handoffAt - now ))
  if [ "$untilHandoff" -lt "$sleepFor" ]; then
    sleepFor=$untilHandoff
  fi
  if [ "$sleepFor" -gt 0 ]; then
    sleep "$sleepFor"
  fi
done
