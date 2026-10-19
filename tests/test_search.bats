#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-b
  bash "$SCRIPTS/join.sh" testteam carol claude-code /tmp/project-c
}

teardown() {
  teardown_test_env
}

# --- search.sh: normal cases ---

@test "search: finds messages containing the keyword" {
  bash "$SCRIPTS/send.sh" testteam alice bob "deploy finished"
  bash "$SCRIPTS/send.sh" testteam bob alice "lunch?"
  run bash "$SCRIPTS/search.sh" testteam deploy
  [ "$status" -eq 0 ]
  [[ "$output" =~ "deploy finished" ]] || false
  [[ ! "$output" =~ "lunch?" ]] || false
}

@test "search: matches a keyword in the middle of a message" {
  bash "$SCRIPTS/send.sh" testteam alice bob "the quick brown fox"
  run bash "$SCRIPTS/search.sh" testteam "brown"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "the quick brown fox" ]] || false
}

@test "search: ASCII match is case-insensitive" {
  bash "$SCRIPTS/send.sh" testteam alice bob "Release Notes ready"
  run bash "$SCRIPTS/search.sh" testteam "release notes"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Release Notes ready" ]] || false
}

@test "search: finds Japanese keywords" {
  bash "$SCRIPTS/send.sh" testteam alice bob "本番環境へのデプロイが完了しました"
  bash "$SCRIPTS/send.sh" testteam alice bob "ランチに行きます"
  run bash "$SCRIPTS/search.sh" testteam "デプロイ"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "本番環境へのデプロイが完了しました" ]] || false
  [[ ! "$output" =~ "ランチ" ]] || false
}

@test "search: output uses the history format with sender and recipient" {
  bash "$SCRIPTS/send.sh" testteam alice bob "needle"
  run bash "$SCRIPTS/search.sh" testteam needle
  [ "$status" -eq 0 ]
  [[ "$output" =~ "alice → bob: needle" ]] || false
}

@test "search: filters by agent (sender or recipient)" {
  bash "$SCRIPTS/send.sh" testteam alice bob "needle one"
  bash "$SCRIPTS/send.sh" testteam bob carol "needle two"
  bash "$SCRIPTS/send.sh" testteam carol alice "needle three"
  run bash "$SCRIPTS/search.sh" testteam needle bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "needle one" ]] || false
  [[ "$output" =~ "needle two" ]] || false
  [[ ! "$output" =~ "needle three" ]] || false
}

@test "search: only searches the given team" {
  bash "$SCRIPTS/join.sh" other alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" other bob claude-code /tmp/project-b
  bash "$SCRIPTS/send.sh" testteam alice bob "needle in testteam"
  bash "$SCRIPTS/send.sh" other alice bob "needle in other"
  run bash "$SCRIPTS/search.sh" testteam needle
  [ "$status" -eq 0 ]
  [[ "$output" =~ "needle in testteam" ]] || false
  [[ ! "$output" =~ "needle in other" ]] || false
}

@test "search: respects limit and keeps the newest matches" {
  bash "$SCRIPTS/send.sh" testteam alice bob "needle 1"
  bash "$SCRIPTS/send.sh" testteam alice bob "needle 2"
  bash "$SCRIPTS/send.sh" testteam alice bob "needle 3"
  run bash "$SCRIPTS/search.sh" testteam needle "" 2
  [ "$status" -eq 0 ]
  local count=$(echo "$output" | grep -c "→")
  [ "$count" -eq 2 ]
  [[ ! "$output" =~ "needle 1" ]] || false
  [[ "$output" =~ "needle 2" ]] || false
  [[ "$output" =~ "needle 3" ]] || false
}

@test "search: shows matches oldest first" {
  bash "$SCRIPTS/send.sh" testteam alice bob "needle first"
  bash "$SCRIPTS/send.sh" testteam alice bob "needle second"
  run bash "$SCRIPTS/search.sh" testteam needle
  [ "$status" -eq 0 ]
  local first_line=$(echo "$output" | grep -n "needle first" | cut -d: -f1)
  local second_line=$(echo "$output" | grep -n "needle second" | cut -d: -f1)
  [ "$first_line" -lt "$second_line" ]
}

@test "search: handles multiline message body" {
  bash "$SCRIPTS/send.sh" testteam alice bob "first line
needle on second line"
  run bash "$SCRIPTS/search.sh" testteam needle
  [ "$status" -eq 0 ]
  [[ "$output" =~ "needle on second line" ]] || false
}

# --- search.sh: error and edge cases ---

@test "search: fails without required args" {
  run bash "$SCRIPTS/search.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage: search.sh" ]] || false
}

@test "search: fails without a keyword" {
  run bash "$SCRIPTS/search.sh" testteam
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage: search.sh" ]] || false
}

@test "search: fails on an empty keyword" {
  run bash "$SCRIPTS/search.sh" testteam ""
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage: search.sh" ]] || false
}

@test "search: reports no matches when nothing contains the keyword" {
  bash "$SCRIPTS/send.sh" testteam alice bob "hello"
  run bash "$SCRIPTS/search.sh" testteam missing
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No matching messages" ]] || false
}

@test "search: reports no matches for an unknown team" {
  bash "$SCRIPTS/send.sh" testteam alice bob "needle"
  run bash "$SCRIPTS/search.sh" no-such-team needle
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No matching messages" ]] || false
}

@test "search: reports an uninitialized DB without failing" {
  rm -f "$TEST_SKILL_DIR/db/messages.db"
  run bash "$SCRIPTS/search.sh" testteam needle
  [ "$status" -eq 0 ]
  [[ "$output" =~ "DB not initialized" ]] || false
}

@test "search: a non-numeric limit falls back to the default instead of injecting SQL" {
  bash "$SCRIPTS/send.sh" testteam alice bob "needle 1"
  bash "$SCRIPTS/send.sh" testteam alice bob "needle 2"
  run bash "$SCRIPTS/search.sh" testteam needle "" "1; DELETE FROM messages; --"
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/search.sh" testteam needle
  [[ "$output" =~ "needle 1" ]] || false
  [[ "$output" =~ "needle 2" ]] || false
}

@test "search: a keyword containing a quote does not break the query or inject SQL" {
  bash "$SCRIPTS/send.sh" testteam alice bob "it's a needle"
  bash "$SCRIPTS/send.sh" testteam alice bob "other message"
  run bash "$SCRIPTS/search.sh" testteam "it's"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "it's a needle" ]] || false
  run bash "$SCRIPTS/search.sh" testteam "x%' OR 1=1; DELETE FROM messages; --"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No matching messages" ]] || false
  run bash "$SCRIPTS/history.sh" testteam
  [[ "$output" =~ "other message" ]] || false
}

@test "search: LIKE wildcards in the keyword are matched literally" {
  bash "$SCRIPTS/send.sh" testteam alice bob "progress 100% done"
  bash "$SCRIPTS/send.sh" testteam alice bob "progress 100 items"
  bash "$SCRIPTS/send.sh" testteam alice bob "snake_case name"
  bash "$SCRIPTS/send.sh" testteam alice bob "snakeXcase name"
  run bash "$SCRIPTS/search.sh" testteam "100%"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "100% done" ]] || false
  [[ ! "$output" =~ "100 items" ]] || false
  run bash "$SCRIPTS/search.sh" testteam "snake_case"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "snake_case name" ]] || false
  [[ ! "$output" =~ "snakeXcase" ]] || false
}

@test "search: a backslash in the keyword is matched literally" {
  bash "$SCRIPTS/send.sh" testteam alice bob 'path C:\temp\file'
  bash "$SCRIPTS/send.sh" testteam alice bob "path C:/temp/file"
  run bash "$SCRIPTS/search.sh" testteam 'C:\temp'
  [ "$status" -eq 0 ]
  [[ "$output" =~ 'C:\temp\file' ]] || false
  [[ ! "$output" =~ "C:/temp/file" ]] || false
}
