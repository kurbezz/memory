#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Test the script the skill actually ships; the root bin/memory is only a convenience symlink.
MEMORY="$ROOT/skills/agent-memory/bin/memory"
PASS=0; FAIL=0

setup() {
  set -e
  TMP="$(mktemp -d)"
  export AGENT_MEMORY_HOME="$TMP/store"
  export HOME="$TMP/home"                 # isolates global git config too
  unset XDG_CONFIG_HOME                   # CI runners set it; config must follow $HOME
  export GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  git config --global user.email "test@example.com"
  git config --global user.name "Test"
  git config --global init.defaultBranch main
  PROJ="$TMP/code/some-api"
  mkdir -p "$PROJ"
  cd "$PROJ"
}

fail() { echo "  assertion failed: $*"; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "no '$2' in: $1" ;; esac; }
assert_link() {
  [ -L "$1" ] || fail "$1 is not a symlink"
  local expected
  expected="$(cd -P "$(dirname "$2")" && pwd -P)/$(basename "$2")"
  assert_eq "$(readlink "$1")" "$expected"
}
assert_file() { [ -f "$1" ] || fail "missing file: $1"; }

extract_cursor_body() {   # extract_cursor_body <cursor-rule> <output>
  local body_line
  body_line="$(awk 'NR == 1 && $0 == "---" { skip = 1; next } skip && /^---$/ { print NR + 1; exit }' "$1")"
  [ -n "$body_line" ] || return 1
  tail -n +"$body_line" "$1" > "$2"
}

test_integration_snippets_exist_and_agree() {
  local s="$ROOT/integrations/agent-memory.snippet.md" c="$ROOT/integrations/cursor/agent-memory.mdc" body="$TMP/cursor-body.md" key
  assert_file "$s"; assert_file "$c"; assert_file "$ROOT/integrations/README.md"
  grep -qF 'OpenCode V2' "$ROOT/README.md" || fail "README does not identify the V2 plugin integration"
  grep -qF 'restart OpenCode' "$ROOT/README.md" || fail "README lacks the required restart instruction"
  # shellcheck disable=SC2016 # The backticks are literal snippet test data.
  for key in '.memory/project/INDEX.md' '.memory/groups/*/INDEX.md' '.memory/workspace/INDEX.md' \
             'memory index' 'memory grep' 'never run `memory init`' 'Never store secrets' 'description:' 'type:'; do
    grep -qF -- "$key" "$s" || fail "snippet lacks: $key"
  done
  assert_eq "$(head -1 "$c")" "---"
  grep -q '^alwaysApply: true$' "$c" || fail "cursor rule is not alwaysApply"
  extract_cursor_body "$c" "$body" || fail "could not extract cursor rule body"
  cmp -s "$body" "$s" || fail "cursor rule body differs from snippet"
}

test_integration_cursor_body_detects_final_newline_drift() {
  local s="$TMP/snippet.md" c="$TMP/cursor.mdc" body="$TMP/cursor-body.md"
  printf 'body\n' > "$s"
  printf '%s\n' '---' 'description: fixture' 'alwaysApply: true' '---' 'body' '' > "$c"
  extract_cursor_body "$c" "$body"
  if cmp -s "$body" "$s"; then fail "cursor body comparison ignored final-newline drift"; fi
}

write_fact_only() {   # write_fact_only <level-dir> <slug> <type> <description>  (no INDEX line)
  cat > "$1/$2.md" <<EOF
---
description: $4
type: $3
created: 2026-09-04
---
body of $2
EOF
}

write_fact() {   # write_fact <level-dir> <slug> <type> <description>
  cat > "$1/$2.md" <<EOF
---
description: $4
type: $3
created: 2026-09-04
---
body of $2
EOF
  printf -- '- [%s](%s.md) — %s: %s\n' "$2" "$2" "$3" "$4" >> "$1/INDEX.md"
}

fill_index() {   # fill_index <INDEX.md> <count>
  local i
  for i in $(seq 1 "$2"); do printf -- '- [f%03d](f%03d.md) — gotcha: entry %d\n' "$i" "$i" "$i" >> "$1"; done
}

run_test() {
  # Run setup and the test together, outside an `if` condition, so errexit is
  # active for both.  The subshell keeps its cwd and temporary environment.
  (
    setup
    trap 'cd /; rm -rf "$TMP"' EXIT
    "$1"
  )
  local rc=$?
  if [ "$rc" -eq 0 ]; then PASS=$((PASS+1)); echo "ok - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi
}

# ---------------- tests ----------------

test_backup_explains_commit_failure() {
  "$MEMORY" init work >/dev/null
  write_fact .memory/project a-fact context "something learned"
  git config --global --unset user.email
  git config --global user.useConfigOnly true      # make git refuse to guess an identity
  local out rc=0
  out="$("$MEMORY" backup 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "user.email"
}

test_usage_without_args() {
  local out rc=0
  out="$("$MEMORY" 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage:"
}

test_unknown_command() {
  local out rc=0
  out="$("$MEMORY" frobnicate 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown command"
}

test_version_flag() {
  local out rc=0
  out="$("$MEMORY" --version)"
  assert_eq "$out" "memory 0.1.0"
  out="$("$MEMORY" -v)"
  assert_eq "$out" "memory 0.1.0"
  out="$("$MEMORY" --version extra 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: memory --version"
}

test_init_creates_structure() {
  local out
  out="$("$MEMORY" init work 2>&1)"
  assert_contains "$out" "initialized"
  assert_link .memory/project "$AGENT_MEMORY_HOME/work/projects/some-api"
  assert_link .memory/workspace "$AGENT_MEMORY_HOME/work/workspace"
  [ -d .memory/groups ] || fail "missing .memory/groups"
  assert_file "$AGENT_MEMORY_HOME/work/projects/some-api/INDEX.md"
  assert_file "$AGENT_MEMORY_HOME/work/workspace/INDEX.md"
  assert_eq "$(cat "$AGENT_MEMORY_HOME/work/projects/some-api/.project-path")" "$(cd -P "$PROJ" && pwd -P)"
  [ -d "$AGENT_MEMORY_HOME/.git" ] || fail "store is not a git repo"
}

test_init_respects_name_flag() {
  "$MEMORY" init work --name custom-name >/dev/null
  assert_link .memory/project "$AGENT_MEMORY_HOME/work/projects/custom-name"
}

test_rejects_path_traversal_names() {
  local out rc=0
  out="$("$MEMORY" init ../evil 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid workspace name"
  "$MEMORY" init work >/dev/null
  rc=0
  out="$("$MEMORY" link-group ../../x 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid group name"
}

test_relative_memory_home_creates_absolute_links() {
  export AGENT_MEMORY_HOME="relative-store"
  "$MEMORY" init work >/dev/null
  assert_link .memory/project "$PROJ/relative-store/work/projects/some-api"
  assert_link .memory/workspace "$PROJ/relative-store/work/workspace"
}

test_init_adds_global_gitignore() {
  "$MEMORY" init work >/dev/null
  local f
  f="$(git config --global core.excludesfile)"
  grep -qxF '.memory/' "$f" || fail "global gitignore lacks .memory/"
}

test_init_without_arg_lists_workspaces() {
  "$MEMORY" init work >/dev/null
  local out rc=0
  out="$("$MEMORY" init 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "work"
  assert_contains "$out" "usage"
}

test_init_is_idempotent_and_repairs() {
  "$MEMORY" init work >/dev/null
  rm .memory/project                       # simulate a broken/deleted symlink
  "$MEMORY" init work >/dev/null
  assert_link .memory/project "$AGENT_MEMORY_HOME/work/projects/some-api"
}

test_init_name_collision() {
  "$MEMORY" init work >/dev/null
  local other="$TMP/elsewhere/some-api"
  mkdir -p "$other"; cd "$other"
  local out rc=0
  out="$("$MEMORY" init work 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "--name"
  "$MEMORY" init work --name some-api-2 >/dev/null
  assert_link .memory/project "$AGENT_MEMORY_HOME/work/projects/some-api-2"
}

test_reinit_after_rename_keeps_binding() {
  "$MEMORY" init work >/dev/null
  cd "$TMP"; mv "$PROJ" "$TMP/code/renamed-api"; cd "$TMP/code/renamed-api"
  "$MEMORY" init work >/dev/null
  # still bound to the original store dir, no second dir created
  assert_link .memory/project "$AGENT_MEMORY_HOME/work/projects/some-api"
  [ ! -d "$AGENT_MEMORY_HOME/work/projects/renamed-api" ] \
    || fail "created a duplicate store dir"
  # backlink updated to the new location
  assert_eq "$(cat .memory/project/.project-path)" "$(pwd -P)"
}

test_init_via_symlinked_path_is_not_a_collision() {
  "$MEMORY" init work >/dev/null
  ln -s "$TMP/code" "$TMP/alias"
  cd "$TMP/alias/some-api"
  "$MEMORY" init work --name some-api >/dev/null
  assert_link .memory/project "$AGENT_MEMORY_HOME/work/projects/some-api"
}

test_init_rebinds_when_recorded_path_does_not_exist_here() {
  mkdir -p "$AGENT_MEMORY_HOME/work/projects/some-api"
  : > "$AGENT_MEMORY_HOME/work/projects/some-api/INDEX.md"
  printf '%s\n' "/home/other-machine/some-api" > "$AGENT_MEMORY_HOME/work/projects/some-api/.project-path"
  "$MEMORY" init work >/dev/null
  assert_link .memory/project "$AGENT_MEMORY_HOME/work/projects/some-api"
  assert_eq "$(cat .memory/project/.project-path)" "$(pwd -P)"
}

test_reinit_with_different_workspace_is_rejected() {
  "$MEMORY" init work >/dev/null
  local out rc=0
  out="$("$MEMORY" init home 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unlink/rebind"
}

test_link_group() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" link-group spines >/dev/null
  assert_link .memory/groups/spines "$AGENT_MEMORY_HOME/work/groups/spines"
  assert_file "$AGENT_MEMORY_HOME/work/groups/spines/INDEX.md"
}

test_link_multiple_groups() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" link-group spines >/dev/null
  "$MEMORY" link-group python-services >/dev/null
  assert_link .memory/groups/spines "$AGENT_MEMORY_HOME/work/groups/spines"
  assert_link .memory/groups/python-services "$AGENT_MEMORY_HOME/work/groups/python-services"
}

test_link_group_requires_init() {
  local out rc=0
  out="$("$MEMORY" link-group spines 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "memory init"
}

test_unlink_group() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" link-group spines >/dev/null
  "$MEMORY" unlink-group spines >/dev/null
  [ ! -e .memory/groups/spines ] || fail "symlink still present"
  [ -d "$AGENT_MEMORY_HOME/work/groups/spines" ] || fail "group memory was deleted"
}

test_unlink_group_not_linked() {
  "$MEMORY" init work >/dev/null
  local out rc=0
  out="$("$MEMORY" unlink-group nope 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "not linked"
}

test_doctor_ok() {
  "$MEMORY" init work >/dev/null
  local out
  out="$("$MEMORY" doctor)"
  assert_contains "$out" "OK"
}

test_doctor_broken_symlink() {
  "$MEMORY" init work >/dev/null
  rm -rf "$AGENT_MEMORY_HOME/work/projects/some-api"
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "BROKEN"
}

test_doctor_flags_plain_project_or_workspace() {
  "$MEMORY" init work >/dev/null
  rm .memory/project
  mkdir .memory/project
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "NOT A SYMLINK: .memory/project"
}

test_doctor_without_memory_dir_says_so() {
  local out
  out="$("$MEMORY" doctor)"            # exit 0: not an error state
  assert_contains "$out" "no .memory/"
  case "$out" in *OK*) fail "doctor printed OK with nothing to check" ;; esac
}

test_doctor_no_valid_levels_does_not_crash() {
  "$MEMORY" init work >/dev/null
  rm .memory/project .memory/workspace
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "MISSING LINK: .memory/project"
  assert_contains "$out" "MISSING LINK: .memory/workspace"
  case "$out" in *"unbound variable"*) fail "doctor crashed: $out" ;; esac
}

test_doctor_store_missing() {
  "$MEMORY" init work >/dev/null
  rm -rf "$AGENT_MEMORY_HOME"
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "STORE MISSING: "
  case "$out" in *"UNSAFE"*) fail "missing store misreported as unsafe: $out" ;; esac
}

test_doctor_unsafe_symlink_outside_store() {
  "$MEMORY" init work >/dev/null
  mkdir -p "$TMP/outside"
  rm .memory/project
  ln -s "$TMP/outside" .memory/project
  local out rc=0 store
  store="$(cd -P "$AGENT_MEMORY_HOME" && pwd -P)"
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "UNSAFE SYMLINK: .memory/project"
  assert_contains "$out" "(outside $store)"
}

test_doctor_relative_symlink_is_unsafe() {
  "$MEMORY" init work >/dev/null
  rm .memory/project
  ln -s ../somewhere .memory/project
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "UNSAFE SYMLINK: .memory/project"
  assert_contains "$out" "relative"
}

test_doctor_file_not_in_index() {
  "$MEMORY" init work >/dev/null
  cat > .memory/project/some-fact.md <<'EOF'
---
description: a fact
type: gotcha
created: 2026-07-07
---
body
EOF
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "NOT IN INDEX"
}

test_doctor_index_entry_without_file() {
  "$MEMORY" init work >/dev/null
  echo "- [ghost](ghost.md) — gotcha: long gone" > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "MISSING FILE"
}

test_doctor_flags_malformed_index_entry() {
  "$MEMORY" init work >/dev/null
  echo "this is not an index entry" > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "MALFORMED INDEX ENTRY"
}

test_doctor_accepts_hyphen_and_en_dash_in_index() {
  "$MEMORY" init work >/dev/null
  write_fact_only .memory/project a-fact gotcha "hyphen line"
  write_fact_only .memory/project b-fact gotcha "en dash line"
  printf -- '- [a-fact](a-fact.md) - gotcha: hyphen line\n' > .memory/project/INDEX.md
  printf -- '- [b-fact](b-fact.md) – gotcha: en dash line\n' >> .memory/project/INDEX.md
  local out
  out="$("$MEMORY" doctor)"
  assert_contains "$out" "OK"
}

test_doctor_accepts_valid_updated_field() {
  "$MEMORY" init work >/dev/null
  cat > .memory/project/a-fact.md <<'EOF'
---
description: has an updated date
type: decision
created: 2026-07-01
updated: 2026-09-04
---
body
EOF
  printf -- '- [a-fact](a-fact.md) — decision: has an updated date\n' > .memory/project/INDEX.md
  assert_contains "$("$MEMORY" doctor)" "OK"
}

test_doctor_flags_updated_before_created() {
  "$MEMORY" init work >/dev/null
  cat > .memory/project/a-fact.md <<'EOF'
---
description: time travel
type: decision
created: 2026-09-04
updated: 2026-01-01
---
body
EOF
  printf -- '- [a-fact](a-fact.md) — decision: time travel\n' > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "updated 2026-01-01 is before created 2026-09-04"
}

test_doctor_flags_invalid_updated_format() {
  "$MEMORY" init work >/dev/null
  cat > .memory/project/a-fact.md <<'EOF'
---
description: bad updated
type: decision
created: 2026-09-04
updated: yesterday
---
body
EOF
  printf -- '- [a-fact](a-fact.md) — decision: bad updated\n' > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid updated date"
}

test_doctor_flags_crlf_frontmatter() {
  "$MEMORY" init work >/dev/null
  printf -- '---\r\ndescription: windows file\r\ntype: gotcha\r\ncreated: 2026-09-04\r\n---\r\nbody\r\n' > .memory/project/crlf.md
  printf -- '- [crlf](crlf.md) — gotcha: windows file\n' > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "CRLF"
}

test_index_generates_sorted_index_from_frontmatter() {
  "$MEMORY" init work >/dev/null
  write_fact_only .memory/project zeta-fact gotcha "last by slug"
  write_fact_only .memory/project alpha-fact decision "first by slug"
  local out
  out="$("$MEMORY" index)"
  assert_contains "$out" "indexed .memory/project (2 facts)"
  assert_eq "$(cat .memory/project/INDEX.md)" "$(printf -- '- [alpha-fact](alpha-fact.md) — decision: first by slug\n- [zeta-fact](zeta-fact.md) — gotcha: last by slug')"
  assert_contains "$("$MEMORY" doctor)" "OK"
}

test_index_covers_groups_and_workspace() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" link-group spines >/dev/null
  write_fact_only .memory/groups/spines shared convention "shared thing"
  write_fact_only .memory/workspace editor context "user prefers vim"
  "$MEMORY" index >/dev/null
  assert_contains "$(cat .memory/groups/spines/INDEX.md)" "[shared](shared.md) — convention: shared thing"
  assert_contains "$(cat .memory/workspace/INDEX.md)" "[editor](editor.md) — context: user prefers vim"
}

test_index_skips_unusable_facts_and_doctor_still_reports_them() {
  "$MEMORY" init work >/dev/null
  write_fact_only .memory/project good gotcha "fine"
  echo "no frontmatter at all" > .memory/project/naked.md
  local out rc=0
  out="$("$MEMORY" index 2>&1)" || rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "skipping .memory/project/naked.md"
  assert_eq "$(grep -c . .memory/project/INDEX.md)" 1
  rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "NOT IN INDEX: .memory/project/naked.md"
}

test_index_requires_memory_dir() {
  local out rc=0
  out="$("$MEMORY" index 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "no .memory/"
}

test_index_rejects_unsafe_project_link_without_writing_external_store() {
  "$MEMORY" init work >/dev/null
  local outside="$TMP/outside" out rc=0
  mkdir -p "$outside"
  printf 'external sentinel\n' > "$outside/INDEX.md"
  rm .memory/project
  ln -s "$outside" .memory/project
  out="$("$MEMORY" index 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" ".memory/project"
  assert_eq "$(cat "$outside/INDEX.md")" "external sentinel"
}

test_index_does_not_follow_preexisting_temp_symlink() {
  "$MEMORY" init work >/dev/null
  write_fact_only .memory/project safe gotcha "safe fact"
  local outside="$TMP/outside"
  mkdir -p "$outside"
  printf 'external sentinel\n' > "$outside/sentinel"
  ln -s "$outside/sentinel" .memory/project/INDEX.md.tmp
  "$MEMORY" index >/dev/null
  assert_eq "$(cat "$outside/sentinel")" "external sentinel"
}

test_index_skips_invalid_frontmatter_type_and_created_values() {
  "$MEMORY" init work >/dev/null
  write_fact_only .memory/project good gotcha "good fact"
  write_fact_only .memory/project bad-type banana "bad type"
  cat > .memory/project/bad-created.md <<'EOF'
---
description: bad date
type: gotcha
created: today
---
body
EOF
  printf 'no frontmatter\n' > .memory/project/no-frontmatter.md
  local out
  out="$("$MEMORY" index 2>&1)"
  assert_contains "$out" "skipping .memory/project/bad-type.md"
  assert_contains "$out" "skipping .memory/project/bad-created.md"
  assert_contains "$out" "skipping .memory/project/no-frontmatter.md"
  assert_eq "$(cat .memory/project/INDEX.md)" "$(printf -- '- [good](good.md) — gotcha: good fact')"
}

test_index_skips_mixed_crlf_frontmatter() {
  "$MEMORY" init work >/dev/null
  write_fact_only .memory/project good gotcha "good fact"
  printf -- '---\ndescription: windows fact\r\ntype: gotcha\ncreated: 2026-09-04\n---\nbody\n' > .memory/project/mixed-crlf.md
  local out
  out="$("$MEMORY" index 2>&1)"
  assert_contains "$out" "skipping .memory/project/mixed-crlf.md"
  assert_eq "$(cat .memory/project/INDEX.md)" "$(printf -- '- [good](good.md) — gotcha: good fact')"
}

test_doctor_and_index_reject_duplicate_updated_fields() {
  "$MEMORY" init work >/dev/null
  cat > .memory/project/a-fact.md <<'EOF'
---
description: duplicate updated
type: decision
created: 2026-09-04
updated: yesterday
updated: 2026-09-04
---
body
EOF
  printf -- '- [a-fact](a-fact.md) — decision: duplicate updated\n' > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid updated date"
  out="$("$MEMORY" index 2>&1)"
  assert_contains "$out" "skipping .memory/project/a-fact.md"
  assert_eq "$(grep -c . .memory/project/INDEX.md || true)" 0
}

test_doctor_checks_exact_index_membership() {
  "$MEMORY" init work >/dev/null
  write_fact_only .memory/project a-fact gotcha "missing from index"
  write_fact_only .memory/project other gotcha "mentions ](a-fact.md)"
  printf -- '- [other](other.md) — gotcha: mentions ](a-fact.md)\n' > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "NOT IN INDEX: .memory/project/a-fact.md"
}

test_index_fails_when_no_usable_linked_level_exists() {
  mkdir -p "$AGENT_MEMORY_HOME" .memory/groups
  local out rc=0
  out="$("$MEMORY" index 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "no usable linked levels"
}

test_index_sort_failure_preserves_existing_indexes() {
  "$MEMORY" init work >/dev/null
  write_fact_only .memory/project a-fact gotcha "a fact"
  printf 'project sentinel\n' > .memory/project/INDEX.md
  printf 'workspace sentinel\n' > .memory/workspace/INDEX.md
  mkdir -p "$TMP/fake-bin"
  cat > "$TMP/fake-bin/sort" <<'EOF'
#!/bin/sh
exit 42
EOF
  chmod +x "$TMP/fake-bin/sort"
  local out rc=0
  out="$(PATH="$TMP/fake-bin:$PATH" "$MEMORY" index 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "failed to render index"
  assert_eq "$(cat .memory/project/INDEX.md)" "project sentinel"
  assert_eq "$(cat .memory/workspace/INDEX.md)" "workspace sentinel"
}

test_index_broken_required_and_group_links_fail_without_publishing() {
  "$MEMORY" init work >/dev/null
  printf 'project sentinel\n' > .memory/project/INDEX.md
  rm .memory/workspace
  ln -s "$AGENT_MEMORY_HOME/work/missing-workspace" .memory/workspace
  local out rc=0
  out="$("$MEMORY" index 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "broken required memory link"
  assert_eq "$(cat .memory/project/INDEX.md)" "project sentinel"

  ln -sfn "$AGENT_MEMORY_HOME/work/workspace" .memory/workspace
  "$MEMORY" link-group spines >/dev/null
  rm .memory/groups/spines
  ln -s "$AGENT_MEMORY_HOME/work/groups/missing-spines" .memory/groups/spines
  rc=0
  out="$("$MEMORY" index 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "broken group memory link"
  assert_eq "$(cat .memory/project/INDEX.md)" "project sentinel"
}

test_index_rejects_directory_destinations_before_any_publish() {
  "$MEMORY" init work >/dev/null
  write_fact_only .memory/project a-fact gotcha "a fact"
  printf 'project sentinel\n' > .memory/project/INDEX.md
  rm .memory/workspace/INDEX.md
  mkdir .memory/workspace/INDEX.md
  local out rc=0
  out="$("$MEMORY" index 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid index destination"
  assert_eq "$(cat .memory/project/INDEX.md)" "project sentinel"
  rmdir .memory/workspace/INDEX.md

  local outside="$TMP/outside-index"
  mkdir "$outside"
  ln -s "$outside" .memory/workspace/INDEX.md
  rc=0
  out="$("$MEMORY" index 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid index destination"
  assert_eq "$(cat .memory/project/INDEX.md)" "project sentinel"
  rm .memory/workspace/INDEX.md
  rmdir "$outside"
}

test_doctor_and_index_reject_duplicate_description() {
  "$MEMORY" init work >/dev/null
  cat > .memory/project/duplicate.md <<'EOF'
---
description:
description: valid description
type: gotcha
created: 2026-09-04
---
body
EOF
  printf -- '- [duplicate](duplicate.md) — gotcha: valid description\n' > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "missing or duplicate description"
  out="$("$MEMORY" index 2>&1)"
  assert_contains "$out" "skipping .memory/project/duplicate.md"
  assert_eq "$(grep -c . .memory/project/INDEX.md || true)" 0
}

test_doctor_and_index_reject_duplicate_type() {
  "$MEMORY" init work >/dev/null
  cat > .memory/project/duplicate.md <<'EOF'
---
description: valid description
type: banana
type: gotcha
created: 2026-09-04
---
body
EOF
  printf -- '- [duplicate](duplicate.md) — gotcha: valid description\n' > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "missing or invalid type"
  out="$("$MEMORY" index 2>&1)"
  assert_contains "$out" "skipping .memory/project/duplicate.md"
  assert_eq "$(grep -c . .memory/project/INDEX.md || true)" 0
}

test_doctor_and_index_reject_duplicate_created() {
  "$MEMORY" init work >/dev/null
  cat > .memory/project/duplicate.md <<'EOF'
---
description: valid description
type: gotcha
created: yesterday
created: 2026-09-04
---
body
EOF
  printf -- '- [duplicate](duplicate.md) — gotcha: valid description\n' > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "missing or invalid created date"
  out="$("$MEMORY" index 2>&1)"
  assert_contains "$out" "skipping .memory/project/duplicate.md"
  assert_eq "$(grep -c . .memory/project/INDEX.md || true)" 0
}

test_doctor_and_index_reject_invalid_calendar_dates() {
  "$MEMORY" init work >/dev/null
  cat > .memory/project/bad-created.md <<'EOF'
---
description: non-leap day
type: gotcha
created: 2026-02-29
---
body
EOF
  cat > .memory/project/bad-month.md <<'EOF'
---
description: bad month
type: gotcha
created: 2026-13-01
---
body
EOF
  cat > .memory/project/bad-updated.md <<'EOF'
---
description: bad updated day
type: gotcha
created: 2024-02-29
updated: 2025-02-29
---
body
EOF
  cat > .memory/project/leap-day.md <<'EOF'
---
description: valid leap day
type: gotcha
created: 2024-02-29
updated: 2024-02-29
---
body
EOF
  "$MEMORY" index >/dev/null
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid created date"
  assert_contains "$out" "invalid updated date"
  out="$("$MEMORY" index 2>&1)"
  assert_contains "$out" "skipping .memory/project/bad-created.md"
  assert_contains "$out" "skipping .memory/project/bad-month.md"
  assert_contains "$out" "skipping .memory/project/bad-updated.md"
  assert_eq "$(cat .memory/project/INDEX.md)" "$(printf -- '- [leap-day](leap-day.md) — gotcha: valid leap day')"
}

test_doctor_warns_on_long_description_but_passes() {
  "$MEMORY" init work >/dev/null
  local long
  long="$(printf 'word %.0s' $(seq 1 30))"
  write_fact_only .memory/project wordy gotcha "$long"
  "$MEMORY" index >/dev/null
  local out
  out="$("$MEMORY" doctor)"
  assert_contains "$out" "warnings (not failures):"
  assert_contains "$out" "LONG DESCRIPTION (150 chars > 120): .memory/project/wordy.md"
  assert_contains "$out" "OK"
}

test_doctor_warns_on_index_description_drift() {
  "$MEMORY" init work >/dev/null
  write_fact_only .memory/project a-fact gotcha "new wording"
  printf -- '- [a-fact](a-fact.md) — gotcha: old wording\n' > .memory/project/INDEX.md
  local out
  out="$("$MEMORY" doctor)"
  assert_contains "$out" "INDEX DESCRIPTION DRIFT: .memory/project/a-fact.md"
  assert_contains "$out" "memory index"
  assert_contains "$out" "OK"
}

test_doctor_warns_on_dangling_wiki_link_and_accepts_cross_level() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" link-group spines >/dev/null
  write_fact_only .memory/groups/spines shared-topology reference "shared topology"
  cat > .memory/project/a-fact.md <<'EOF'
---
description: links elsewhere
type: context
created: 2026-09-04
---
See [[shared-topology]] (exists in the group) and [[does-not-exist]].
EOF
  "$MEMORY" index >/dev/null
  local out
  out="$("$MEMORY" doctor)"
  assert_contains "$out" "DANGLING WIKI LINK: .memory/project/a-fact.md -> [[does-not-exist]]"
  case "$out" in *"[[shared-topology]]"*) fail "cross-level link wrongly reported: $out" ;; esac
  assert_contains "$out" "OK"
}

test_doctor_checks_group_levels_too() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" link-group spines >/dev/null
  cat > .memory/groups/spines/shared-fact.md <<'EOF'
---
description: shared
type: convention
created: 2026-07-07
---
body
EOF
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "NOT IN INDEX"
  assert_contains "$out" "spines"
}

test_doctor_bad_frontmatter() {
  "$MEMORY" init work >/dev/null
  cat > .memory/project/bad-fact.md <<'EOF'
---
description: has a bogus type
type: banana
---
body
EOF
  echo "- [bad-fact](bad-fact.md) — has a bogus type" > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "invalid type"
}

test_doctor_missing_frontmatter() {
  "$MEMORY" init work >/dev/null
  echo "just a body, no frontmatter" > .memory/project/naked-fact.md
  echo "- [naked-fact](naked-fact.md) — naked" > .memory/project/INDEX.md
  local out rc=0
  out="$("$MEMORY" doctor 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "FRONTMATTER"
}

test_doctor_does_not_call_stale_project_path_an_orphan() {
  "$MEMORY" init work >/dev/null
  mkdir -p "$AGENT_MEMORY_HOME/work/projects/dead"
  : > "$AGENT_MEMORY_HOME/work/projects/dead/INDEX.md"
  printf '%s\n' "$TMP/gone-forever" \
    > "$AGENT_MEMORY_HOME/work/projects/dead/.project-path"
  local out
  out="$("$MEMORY" doctor)"          # informational only — still exit 0
  assert_contains "$out" "OK"
}

test_rejects_extra_arguments() {
  local out rc=0
  out="$("$MEMORY" init work extra 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: memory init"
  rc=0
  out="$("$MEMORY" doctor extra 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: memory doctor"
  "$MEMORY" init work >/dev/null
  rc=0
  out="$("$MEMORY" link-group one two 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: memory link-group"
}

test_status_shows_levels_counts_and_unlinked_groups() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" link-group spines >/dev/null
  mkdir -p "$AGENT_MEMORY_HOME/work/groups/platform"
  : > "$AGENT_MEMORY_HOME/work/groups/platform/INDEX.md"
  write_fact_only .memory/project a-fact gotcha "a"
  write_fact_only .memory/project b-fact gotcha "b"
  write_fact_only .memory/groups/spines s-fact convention "s"
  local out
  out="$("$MEMORY" status)"
  assert_contains "$out" "store:      $(cd -P "$AGENT_MEMORY_HOME" && pwd -P)"
  assert_contains "$out" "workspace:  work  (0 facts)"
  assert_contains "$out" "project:    some-api  (2 facts)"
  assert_contains "$out" "group:      spines  (1 facts)"
  assert_contains "$out" "not linked: platform"
  assert_contains "$out" "backup:     last never"
}

test_status_reports_backup_state() {
  "$MEMORY" init work >/dev/null
  write_fact_only .memory/project a-fact gotcha "a"
  "$MEMORY" backup >/dev/null
  local out
  out="$("$MEMORY" status)"
  assert_contains "$out" "backup:     last $(date +%Y-%m-%d), store clean"
  write_fact_only .memory/project b-fact gotcha "b"
  out="$("$MEMORY" status)"
  assert_contains "$out" "1 uncommitted path(s) — run 'memory backup'"
}

test_status_requires_init() {
  local out rc=0
  out="$("$MEMORY" status 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "no .memory/"
}

test_grep_searches_bodies_across_levels_following_symlinks() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" link-group spines >/dev/null
  cat > .memory/project/pool.md <<'EOF'
---
description: pool limit
type: gotcha
created: 2026-09-04
---
pgbouncer in transaction mode returns stale statements above 50 connections.
EOF
  cat > .memory/groups/spines/topology.md <<'EOF'
---
description: shared topology
type: reference
created: 2026-09-04
---
All services share one PgBouncer in front of the primary.
EOF
  "$MEMORY" index >/dev/null
  local out
  out="$("$MEMORY" grep pgbouncer)"
  assert_contains "$out" ".memory/project/pool.md:6:pgbouncer in transaction mode"
  assert_contains "$out" ".memory/groups/spines/topology.md:6:All services share one PgBouncer"
}

test_grep_no_match_exits_zero_with_message() {
  "$MEMORY" init work >/dev/null
  local out rc=0
  out="$("$MEMORY" grep nothing-here-at-all)" || rc=$?
  assert_eq "$rc" 0
  assert_eq "$out" "no matches for 'nothing-here-at-all'"
}

test_grep_excludes_project_path_file() {
  "$MEMORY" init work >/dev/null
  local out
  out="$("$MEMORY" grep some-api)"          # the path is recorded in .project-path
  case "$out" in *".project-path"*) fail "matched .project-path: $out" ;; esac
}

test_grep_requires_pattern() {
  "$MEMORY" init work >/dev/null
  local out rc=0
  out="$("$MEMORY" grep 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "usage: memory grep"
}

test_status_rejects_unsafe_and_broken_required_links() {
  "$MEMORY" init work >/dev/null
  rm .memory/workspace
  ln -s "$AGENT_MEMORY_HOME/work/missing-workspace" .memory/workspace
  local out rc=0
  out="$("$MEMORY" status 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unsafe or broken symlink: .memory/workspace (run 'memory doctor')"

  ln -sfn "$AGENT_MEMORY_HOME/work/workspace" .memory/workspace
  mkdir -p "$TMP/outside"
  rm .memory/project
  ln -s "$TMP/outside" .memory/project
  rc=0
  out="$("$MEMORY" status 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unsafe or broken symlink: .memory/project (run 'memory doctor')"
}

test_status_labels_unsafe_and_broken_group_links() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" link-group shared >/dev/null
  mkdir -p "$TMP/outside"
  write_fact_only "$TMP/outside" secret gotcha "outside secret"
  rm .memory/groups/shared
  ln -s "$TMP/outside" .memory/groups/shared
  ln -s "$AGENT_MEMORY_HOME/work/groups/missing" .memory/groups/missing
  local out
  out="$("$MEMORY" status)"
  assert_contains "$out" "group:      shared  (UNSAFE OR BROKEN LINK — run 'memory doctor')"
  assert_contains "$out" "group:      missing  (UNSAFE OR BROKEN LINK — run 'memory doctor')"
  case "$out" in *"outside secret"*|*"$TMP/outside"*|*"shared  (1 facts)"*) fail "disclosed unsafe group data: $out" ;; esac
}

test_status_reports_backup_unavailable_without_git() {
  "$MEMORY" init work >/dev/null
  rm -rf "$AGENT_MEMORY_HOME/.git"
  assert_contains "$("$MEMORY" status)" "backup:     unavailable (store is not a git repository)"
}

test_status_does_not_use_parent_git_repository() {
  local parent="$TMP/parent"
  mkdir -p "$parent"
  git -C "$parent" init -q
  printf 'parent repository\n' > "$parent/README.md"
  git -C "$parent" add README.md
  git -C "$parent" commit -q -m "parent commit"
  export AGENT_MEMORY_HOME="$parent/store"
  "$MEMORY" init work >/dev/null
  rm -rf "$AGENT_MEMORY_HOME/.git"
  assert_contains "$("$MEMORY" status)" "backup:     unavailable (store is not a git repository)"
}

test_status_counts_untracked_when_git_hides_them() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" backup >/dev/null
  git -C "$AGENT_MEMORY_HOME" config status.showUntrackedFiles no
  write_fact_only .memory/project untracked gotcha "still must count"
  assert_contains "$("$MEMORY" status)" "1 uncommitted path(s) — run 'memory backup'"
}

test_grep_rejects_unsafe_and_broken_required_links() {
  "$MEMORY" init work >/dev/null
  mkdir -p "$TMP/outside"
  rm .memory/project
  ln -s "$TMP/outside" .memory/project
  local out rc=0
  out="$("$MEMORY" grep needle 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unsafe or broken symlink: .memory/project (run 'memory doctor')"

  ln -sfn "$AGENT_MEMORY_HOME/work/projects/some-api" .memory/project
  rm .memory/workspace
  ln -s "$AGENT_MEMORY_HOME/work/missing-workspace" .memory/workspace
  rc=0
  out="$("$MEMORY" grep needle 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unsafe or broken symlink: .memory/workspace (run 'memory doctor')"
}

test_grep_rejects_unsafe_and_broken_group_links() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" link-group shared >/dev/null
  mkdir -p "$TMP/outside"
  printf 'external needle\n' > "$TMP/outside/secret.md"
  rm .memory/groups/shared
  ln -s "$TMP/outside" .memory/groups/shared
  local out rc=0
  out="$("$MEMORY" grep needle 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unsafe or broken symlink: .memory/groups/shared (run 'memory doctor')"

  rm .memory/groups/shared
  ln -s "$AGENT_MEMORY_HOME/work/groups/missing" .memory/groups/shared
  rc=0
  out="$("$MEMORY" grep needle 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unsafe or broken symlink: .memory/groups/shared (run 'memory doctor')"
}

test_grep_uses_lowercase_r_to_avoid_nested_symlinks() {
  "$MEMORY" init work >/dev/null
  mkdir -p "$TMP/fake-bin"
  GREP_ARGS="$TMP/grep-args"
  export GREP_ARGS
  cat > "$TMP/fake-bin/grep" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$GREP_ARGS"
exit 1
EOF
  chmod +x "$TMP/fake-bin/grep"
  local out rc=0 args
  out="$(PATH="$TMP/fake-bin:$PATH" "$MEMORY" grep needle)" || rc=$?
  assert_eq "$rc" 0
  assert_eq "$out" "no matches for 'needle'"
  args="$(<"$GREP_ARGS")"
  assert_contains "$args" "-r"
  case "$args" in *"-R"*) fail "grep followed nested symlinks: $args" ;; esac
}

test_backup_commits_store() {
  "$MEMORY" init work >/dev/null
  cat > .memory/project/a-fact.md <<'EOF'
---
description: something learned
type: context
created: 2026-07-07
---
body
EOF
  "$MEMORY" backup >/dev/null
  local n
  n="$(git -C "$AGENT_MEMORY_HOME" rev-list --count HEAD)"
  assert_eq "$n" 1
  if git -C "$AGENT_MEMORY_HOME" status --porcelain | grep -q .; then
    fail "store has uncommitted changes"
  fi
}

test_backup_nothing_to_do() {
  "$MEMORY" init work >/dev/null
  "$MEMORY" backup >/dev/null
  local out
  out="$("$MEMORY" backup)"
  assert_contains "$out" "nothing to back up"
}

test_backup_push_without_remote_fails() {
  "$MEMORY" init work >/dev/null
  local out rc=0
  out="$("$MEMORY" backup --push 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "remote"
}

test_install_opencode_creates_plugin_symlink() {
  "$MEMORY" install-opencode >/dev/null
  assert_link "$HOME/.config/opencode/plugins/agent-memory.js" "$ROOT/skills/agent-memory/opencode/agent-memory.js"
}

test_install_opencode_is_idempotent() {
  "$MEMORY" install-opencode >/dev/null
  local out
  out="$("$MEMORY" install-opencode)"
  assert_contains "$out" "already installed"
}

test_install_opencode_replaces_legacy_symlink_in_xdg_config() {
  export XDG_CONFIG_HOME="$TMP/xdg"
  mkdir -p "$XDG_CONFIG_HOME/opencode/plugins" "$TMP/legacy"
  : > "$TMP/legacy/agent-memory.js"
  ln -s "$TMP/legacy/agent-memory.js" "$XDG_CONFIG_HOME/opencode/plugins/agent-memory.js"
  "$MEMORY" install-opencode >/dev/null
  assert_link "$XDG_CONFIG_HOME/opencode/plugins/agent-memory.js" "$ROOT/skills/agent-memory/opencode/agent-memory.js"
  [ ! -e "$HOME/.config/opencode/plugins/agent-memory.js" ] || fail "wrote HOME config instead of XDG_CONFIG_HOME"
}

test_install_opencode_replaces_dangling_symlink() {
  mkdir -p "$HOME/.config/opencode/plugins"
  ln -s "$TMP/moved/agent-memory.js" "$HOME/.config/opencode/plugins/agent-memory.js"
  "$MEMORY" install-opencode >/dev/null
  assert_link "$HOME/.config/opencode/plugins/agent-memory.js" "$ROOT/skills/agent-memory/opencode/agent-memory.js"
}

test_install_opencode_does_not_write_config_or_presets() {
  export XDG_CONFIG_HOME="$TMP/xdg"
  mkdir -p "$XDG_CONFIG_HOME/opencode"
  printf 'config sentinel\n' > "$XDG_CONFIG_HOME/opencode/opencode.json"
  printf 'preset sentinel\n' > "$XDG_CONFIG_HOME/opencode/oh-my-opencode-slim.json"
  "$MEMORY" install-opencode >/dev/null
  assert_eq "$(<"$XDG_CONFIG_HOME/opencode/opencode.json")" "config sentinel"
  assert_eq "$(<"$XDG_CONFIG_HOME/opencode/oh-my-opencode-slim.json")" "preset sentinel"
}

test_install_opencode_refuses_regular_file() {
  mkdir -p "$HOME/.config/opencode/plugins"
  printf 'keep me\n' > "$HOME/.config/opencode/plugins/agent-memory.js"
  local out rc=0
  out="$("$MEMORY" install-opencode 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "refusing to overwrite"
  assert_eq "$(<"$HOME/.config/opencode/plugins/agent-memory.js")" "keep me"
}

# ---------------- runner ----------------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do run_test "$t"; done
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
