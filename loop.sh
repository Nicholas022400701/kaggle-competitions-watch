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
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
start=$(date +%s)
handoffAt=$(( handoffMin * 60 ))
fails=0
pushChanges() {
  git add -A data COMPETITIONS.md
  if git diff --cached --quiet; then
    return 0
  fi
  git commit -q -m "data: kaggle competitions $(date -u +'%F %H:%MZ')"
  for i in 1 2 3; do
    if git fetch -q origin "$branch" && git rebase -q -X theirs "origin/$branch" && git push -q origin "HEAD:$branch"; then
      echo "pushed $(git rev-parse --short HEAD)"
      return 0
    fi
    git rebase --abort 2>/dev/null || true
    sleep 5
  done
  echo "::warning::push failed, will retry next tick"
  return 1
}
handoff() {
  echo "handoff at $(( $(date +%s) - start ))s: dispatching successor run"
  if gh workflow run "$wf" --repo "$repo" --ref "$branch"; then
    echo "successor dispatched, exiting"
  else
    echo "::warning::handoff dispatch failed, tick.yml restarts the watcher within 5 min"
  fi
}
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
