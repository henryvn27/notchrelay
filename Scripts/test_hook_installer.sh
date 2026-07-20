#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
temporary_directory="$(mktemp -d "${TMPDIR%/}/cowlick-hook-tests.XXXXXX")"
chmod 700 "$temporary_directory"
trap 'rm -rf "$temporary_directory"' EXIT

test_home="$temporary_directory/home"
hooks_directory="$test_home/.codex"
helper="$temporary_directory/cowlick-hook"
mkdir -p "$hooks_directory"
mkdir -p "$test_home/.local/bin"
chmod 755 "$test_home/.local/bin"
print -n -- '#!/bin/zsh\nexit 0\n' > "$helper"
chmod 755 "$helper"

assert_invalid_hooks_rejected_without_residue() {
  local name="$1"
  local payload="$2"
  local invalid_home="$temporary_directory/$name-home"
  local invalid_hooks="$invalid_home/.codex/hooks.json"
  local invalid_snapshot="$temporary_directory/$name-snapshot"
  mkdir -p "${invalid_hooks:h}"
  print -n -- "$payload" > "$invalid_hooks"
  local original_hash="$(shasum -a 256 "$invalid_hooks" | awk '{print $1}')"

  if COWLICK_HOME="$invalid_home" swift "$script_dir/install_hooks.swift" install \
    --helper "$helper" --snapshot "$invalid_snapshot" >/dev/null 2>&1; then
    print -u2 "$name hooks unexpectedly installed"
    exit 1
  fi
  [[ "$(shasum -a 256 "$invalid_hooks" | awk '{print $1}')" == "$original_hash" ]]
  [[ ! -e "$invalid_snapshot" ]]
  [[ ! -e "$invalid_home/.local/bin/cowlick-hook" \
    && ! -L "$invalid_home/.local/bin/cowlick-hook" ]]
  [[ ! -e "$invalid_home/Library/Application Support/Cowlick/bin/cowlick-hook" ]]
}

assert_invalid_hooks_rejected_without_residue malformed '{'
assert_invalid_hooks_rejected_without_residue non-object '[]'

nested_helper_home="$temporary_directory/nested-helper-home"
nested_helper="$nested_helper_home/Library/Application Support/Cowlick/bin/cowlick-hook"
nested_helper_target="$temporary_directory/nested-helper-target"
nested_helper_shim="$nested_helper_home/.local/bin/cowlick-hook"
nested_helper_hooks="$nested_helper_home/.codex/hooks.json"
nested_helper_snapshot="$temporary_directory/nested-helper-snapshot"
mkdir -p "${nested_helper:h}" "${nested_helper_shim:h}" "${nested_helper_hooks:h}"
print -n -- '#!/bin/zsh\nprint nested\n' > "$nested_helper_target"
chmod 755 "$nested_helper_target"
ln -s "$nested_helper_target" "$nested_helper"
ln -s "$nested_helper" "$nested_helper_shim"
print -n -- '{"custom":"preserve","hooks":{}}' > "$nested_helper_hooks"
nested_helper_hooks_hash="$(shasum -a 256 "$nested_helper_hooks" | awk '{print $1}')"
nested_helper_target_hash="$(shasum -a 256 "$nested_helper_target" | awk '{print $1}')"
if COWLICK_HOME="$nested_helper_home" swift "$script_dir/install_hooks.swift" install \
  --helper "$helper" --snapshot "$nested_helper_snapshot" >/dev/null 2>&1; then
  print -u2 "installer accepted a nested helper symlink"
  exit 1
fi
[[ ! -e "$nested_helper_snapshot" ]]
[[ -L "$nested_helper" && "$(readlink "$nested_helper")" == "$nested_helper_target" ]]
[[ -L "$nested_helper_shim" && "$(readlink "$nested_helper_shim")" == "$nested_helper" ]]
[[ "$(shasum -a 256 "$nested_helper_hooks" | awk '{print $1}')" == "$nested_helper_hooks_hash" ]]
[[ "$(shasum -a 256 "$nested_helper_target" | awk '{print $1}')" \
    == "$nested_helper_target_hash" ]]

invalid_restore_home="$temporary_directory/invalid-restore-home"
invalid_restore_helper="$invalid_restore_home/Library/Application Support/Cowlick/bin/cowlick-hook"
invalid_restore_shim="$invalid_restore_home/.local/bin/cowlick-hook"
invalid_restore_hooks="$invalid_restore_home/.codex/hooks.json"
mkdir -p "$invalid_restore_home/.codex"
COWLICK_HOME="$invalid_restore_home" swift "$script_dir/install_hooks.swift" install \
  --helper "$helper" >/dev/null
invalid_restore_helper_hash="$(shasum -a 256 "$invalid_restore_helper" | awk '{print $1}')"
invalid_restore_hooks_hash="$(shasum -a 256 "$invalid_restore_hooks" | awk '{print $1}')"

assert_invalid_snapshot_rejected_without_mutation() {
  local name="$1"
  local snapshot="$2"
  if COWLICK_HOME="$invalid_restore_home" swift "$script_dir/install_hooks.swift" restore \
    --snapshot "$snapshot" >/dev/null 2>&1; then
    print -u2 "$name rollback snapshot unexpectedly restored"
    exit 1
  fi
  [[ "$(shasum -a 256 "$invalid_restore_helper" | awk '{print $1}')" \
      == "$invalid_restore_helper_hash" ]]
  [[ "$(shasum -a 256 "$invalid_restore_hooks" | awk '{print $1}')" \
      == "$invalid_restore_hooks_hash" ]]
  [[ -L "$invalid_restore_shim" && "$(readlink "$invalid_restore_shim")" \
      == "$invalid_restore_helper" ]]
}

missing_marker_snapshot="$temporary_directory/missing-marker-snapshot"
mkdir -p "$missing_marker_snapshot"
cp "$invalid_restore_hooks" "$missing_marker_snapshot/hooks.json"
assert_invalid_snapshot_rejected_without_mutation missing-marker "$missing_marker_snapshot"

malformed_marker_snapshot="$temporary_directory/malformed-marker-snapshot"
mkdir -p "$malformed_marker_snapshot"
cp "$invalid_restore_hooks" "$malformed_marker_snapshot/hooks.json"
print -n -- '2' > "$malformed_marker_snapshot/.cowlick-integration-snapshot-v1"
chmod 600 "$malformed_marker_snapshot/.cowlick-integration-snapshot-v1"
assert_invalid_snapshot_rejected_without_mutation malformed-marker "$malformed_marker_snapshot"

dangling_marker_snapshot="$temporary_directory/dangling-marker-snapshot"
mkdir -p "$dangling_marker_snapshot"
cp "$invalid_restore_hooks" "$dangling_marker_snapshot/hooks.json"
ln -s "$temporary_directory/missing-marker-target" \
  "$dangling_marker_snapshot/.cowlick-integration-snapshot-v1"
assert_invalid_snapshot_rejected_without_mutation dangling-marker "$dangling_marker_snapshot"

migration_home="$temporary_directory/four-event-migration-home"
migration_hooks="$migration_home/.codex/hooks.json"
mkdir -p "${migration_hooks:h}"
COWLICK_TEST_HOME="$migration_home" COWLICK_TEST_HOOKS="$migration_hooks" swift -e '
  import Foundation

  let environment = ProcessInfo.processInfo.environment
  let home = environment["COWLICK_TEST_HOME"]!
  let destination = URL(fileURLWithPath: environment["COWLICK_TEST_HOOKS"]!)
  let owned: [String: Any] = [
    "type": "command",
    "command": "\(home)/.local/bin/cowlick-hook hook",
    "cowlick": ["product": "Cowlick", "protocol": 1],
  ]
  var hooks: [String: Any] = [:]
  for event in ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"] {
    hooks[event] = [["hooks": [owned]]]
  }
  hooks["Stop"] = [[
    "matcher": "preserve",
    "hooks": [owned, ["type": "command", "command": "/usr/local/bin/unrelated"]],
  ]]
  hooks["FutureEvent"] = [[
    "futureGroup": true,
    "hooks": [["type": "command", "command": "/usr/local/bin/future"]],
  ]]
  let root: [String: Any] = [
    "future": ["preserve": true],
    "hooks": hooks,
  ]
  try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    .write(to: destination, options: .atomic)
'
chmod 600 "$migration_hooks"

COWLICK_HOME="$migration_home" swift "$script_dir/install_hooks.swift" install \
  --helper "$helper" >/dev/null
migration_first_hash="$(shasum -a 256 "$migration_hooks" | awk '{print $1}')"
COWLICK_HOME="$migration_home" swift "$script_dir/install_hooks.swift" install \
  --helper "$helper" >/dev/null
migration_second_hash="$(shasum -a 256 "$migration_hooks" | awk '{print $1}')"
[[ "$migration_first_hash" == "$migration_second_hash" ]] \
  || { print -u2 "four-event repair is not idempotent"; exit 1; }

COWLICK_TEST_HOOKS="$migration_hooks" swift -e '
  import Foundation

  let path = ProcessInfo.processInfo.environment["COWLICK_TEST_HOOKS"]!
  let root = try JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
  precondition((root["future"] as? [String: Any])?["preserve"] as? Bool == true)
  let hooks = root["hooks"] as! [String: Any]
  let future = hooks["FutureEvent"] as! [[String: Any]]
  precondition(future.first?["futureGroup"] as? Bool == true)
  let futureCommands = future.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    .compactMap { $0["command"] as? String }
  precondition(futureCommands == ["/usr/local/bin/future"])
  for event in ["SessionStart", "UserPromptSubmit", "PermissionRequest", "SubagentStart", "SubagentStop", "Stop"] {
    let groups = hooks[event] as! [[String: Any]]
    let handlers = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    let owned = handlers.filter {
      ($0["cowlick"] as? [String: Any])?["product"] as? String == "Cowlick"
    }
    precondition(owned.count == 1)
  }
'

COWLICK_HOME="$migration_home" swift "$script_dir/install_hooks.swift" remove >/dev/null
COWLICK_TEST_HOOKS="$migration_hooks" swift -e '
  import Foundation

  let path = ProcessInfo.processInfo.environment["COWLICK_TEST_HOOKS"]!
  let root = try JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
  precondition((root["future"] as? [String: Any])?["preserve"] as? Bool == true)
  let hooks = root["hooks"] as! [String: Any]
  let future = hooks["FutureEvent"] as! [[String: Any]]
  precondition(future.first?["futureGroup"] as? Bool == true)
  let futureCommands = future.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    .compactMap { $0["command"] as? String }
  precondition(futureCommands == ["/usr/local/bin/future"])
  for event in ["SessionStart", "UserPromptSubmit", "PermissionRequest", "SubagentStart", "SubagentStop"] {
    precondition(hooks[event] == nil)
  }
  let stop = hooks["Stop"] as! [[String: Any]]
  precondition(stop.first?["matcher"] as? String == "preserve")
  let commands = stop.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    .compactMap { $0["command"] as? String }
  precondition(commands == ["/usr/local/bin/unrelated"])
'

COWLICK_TEST_HOME="$test_home" COWLICK_TEST_HOOKS="$hooks_directory/hooks.json" swift -e '
  import Foundation

  let environment = ProcessInfo.processInfo.environment
  let home = environment["COWLICK_TEST_HOME"]!
  let destination = URL(fileURLWithPath: environment["COWLICK_TEST_HOOKS"]!)
  let root: [String: Any] = [
    "future": ["preserve": true],
    "hooks": [
      "Stop": [[
        "hooks": [
          ["type": "command", "command": "/usr/local/bin/unrelated"],
          [
            "type": "command",
            "command": "\(home)/.local/bin/notchrelay-hook hook",
            "notchRelay": ["product": "NotchRelay", "protocol": 1],
          ],
        ]
      ]]
    ],
  ]
  try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    .write(to: destination, options: .atomic)
'
chmod 600 "$hooks_directory/hooks.json"

COWLICK_HOME="$test_home" swift "$script_dir/install_hooks.swift" install --helper "$helper" >/dev/null
[[ "$(stat -f '%Lp' "$test_home/.local/bin")" == "755" ]] \
  || { print -u2 "installer changed shared ~/.local/bin permissions"; exit 1; }
first_hash="$(shasum -a 256 "$hooks_directory/hooks.json" | awk '{print $1}')"
COWLICK_HOME="$test_home" swift "$script_dir/install_hooks.swift" install --helper "$helper" >/dev/null
second_hash="$(shasum -a 256 "$hooks_directory/hooks.json" | awk '{print $1}')"
[[ "$first_hash" == "$second_hash" ]] || { print -u2 "hook installation is not idempotent"; exit 1; }
helper_hash="$(shasum -a 256 \
  "$test_home/Library/Application Support/Cowlick/bin/cowlick-hook" | awk '{print $1}')"

assert_installed_fixture_unchanged() {
  [[ "$(shasum -a 256 "$hooks_directory/hooks.json" | awk '{print $1}')" == "$second_hash" ]]
  [[ "$(shasum -a 256 \
      "$test_home/Library/Application Support/Cowlick/bin/cowlick-hook" | awk '{print $1}')" \
      == "$helper_hash" ]]
  [[ -L "$test_home/.local/bin/cowlick-hook" ]]
}

COWLICK_HOME="$test_home" swift "$script_dir/install_hooks.swift" remove --help >/dev/null
assert_installed_fixture_unchanged
for invalid_arguments in 'remove --unknown' 'remove extra' 'status extra' \
  'install --helper /tmp/missing extra'; do
  if COWLICK_HOME="$test_home" swift "$script_dir/install_hooks.swift" \
    ${(z)invalid_arguments} >/dev/null 2>&1; then
    print -u2 "invalid installer arguments unexpectedly succeeded: $invalid_arguments"
    exit 1
  fi
  assert_installed_fixture_unchanged
done

COWLICK_TEST_HOOKS="$hooks_directory/hooks.json" swift -e '
  import Foundation

  let path = ProcessInfo.processInfo.environment["COWLICK_TEST_HOOKS"]!
  let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
  let future = root["future"] as! [String: Any]
  precondition(future["preserve"] as? Bool == true)
  let hooks = root["hooks"] as! [String: Any]
  for event in ["SessionStart", "UserPromptSubmit", "PermissionRequest", "SubagentStart", "SubagentStop", "Stop"] {
    let groups = hooks[event] as! [[String: Any]]
    let handlers = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    let owned = handlers.filter { ($0["cowlick"] as? [String: Any])?["product"] as? String == "Cowlick" }
    precondition(owned.count == 1)
    precondition(!handlers.contains { ($0["command"] as? String)?.contains("notchrelay-hook") == true })
  }
'

replacement_helper="$temporary_directory/replacement-cowlick-hook"
snapshot_directory="$temporary_directory/integration-snapshot"
print -n -- '#!/bin/zsh\nprint replacement\n' > "$replacement_helper"
chmod 755 "$replacement_helper"
COWLICK_HOME="$test_home" swift "$script_dir/install_hooks.swift" install \
  --helper "$replacement_helper" --snapshot "$snapshot_directory" >/dev/null
[[ ! -L "$snapshot_directory/.cowlick-integration-snapshot-v1" ]]
[[ "$(stat -f '%HT %Su %Lp' "$snapshot_directory/.cowlick-integration-snapshot-v1")" \
    == "Regular File $(id -un) 600" ]]
[[ "$(< "$snapshot_directory/.cowlick-integration-snapshot-v1")" == 1 ]]
grep -Fq 'replacement' \
  "$test_home/Library/Application Support/Cowlick/bin/cowlick-hook"
COWLICK_TEST_HOOKS="$hooks_directory/hooks.json" swift -e '
  import Foundation

  let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COWLICK_TEST_HOOKS"]!)
  var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  root["concurrent"] = ["preserve": true]
  var hooks = root["hooks"] as! [String: Any]
  var groups = hooks["Stop"] as! [[String: Any]]
  groups.append(["hooks": [["type": "command", "command": "/usr/local/bin/concurrent"]]])
  hooks["Stop"] = groups
  root["hooks"] = hooks
  try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    .write(to: url, options: .atomic)
'
COWLICK_HOME="$test_home" swift "$script_dir/install_hooks.swift" restore \
  --snapshot "$snapshot_directory" >/dev/null
[[ "$(shasum -a 256 \
    "$test_home/Library/Application Support/Cowlick/bin/cowlick-hook" | awk '{print $1}')" \
    == "$helper_hash" ]]
COWLICK_TEST_HOOKS="$hooks_directory/hooks.json" swift -e '
  import Foundation

  let path = ProcessInfo.processInfo.environment["COWLICK_TEST_HOOKS"]!
  let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
  precondition((root["concurrent"] as? [String: Any])?["preserve"] as? Bool == true)
  let hooks = root["hooks"] as! [String: Any]
  let stop = hooks["Stop"] as! [[String: Any]]
  let commands = stop.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    .compactMap { $0["command"] as? String }
  precondition(commands.contains("/usr/local/bin/unrelated"))
  precondition(commands.contains("/usr/local/bin/concurrent"))
'

COWLICK_HOME="$test_home" swift "$script_dir/install_hooks.swift" remove >/dev/null
COWLICK_TEST_HOOKS="$hooks_directory/hooks.json" swift -e '
  import Foundation

  let path = ProcessInfo.processInfo.environment["COWLICK_TEST_HOOKS"]!
  let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
  precondition((root["future"] as? [String: Any])?["preserve"] as? Bool == true)
  precondition((root["concurrent"] as? [String: Any])?["preserve"] as? Bool == true)
  let hooks = root["hooks"] as! [String: Any]
  let stop = hooks["Stop"] as! [[String: Any]]
  let handlers = stop.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
  let commands = handlers.compactMap { $0["command"] as? String }
  precondition(Set(commands) == ["/usr/local/bin/unrelated", "/usr/local/bin/concurrent"])
  for event in ["SessionStart", "UserPromptSubmit", "PermissionRequest", "SubagentStart", "SubagentStop"] {
    precondition(hooks[event] == nil)
  }
'

foreign_home="$temporary_directory/foreign-home"
foreign_hooks="$foreign_home/.codex/hooks.json"
foreign_installed_helper="$foreign_home/Library/Application Support/Cowlick/bin/cowlick-hook"
mkdir -p "${foreign_hooks:h}" "${foreign_installed_helper:h}"
print -n -- '{"custom":"preserve","hooks":{}}' > "$foreign_hooks"
print -n -- 'foreign-helper' > "$foreign_installed_helper"
foreign_hooks_hash="$(shasum -a 256 "$foreign_hooks" | awk '{print $1}')"
foreign_helper_hash="$(shasum -a 256 "$foreign_installed_helper" | awk '{print $1}')"

if COWLICK_HOME="$foreign_home" swift "$script_dir/install_hooks.swift" \
  install --helper "$helper" >/dev/null 2>&1; then
  print -u2 "installer replaced a foreign helper without an owned shim"
  exit 1
fi
if COWLICK_HOME="$foreign_home" swift "$script_dir/install_hooks.swift" remove \
  >/dev/null 2>&1; then
  print -u2 "remover deleted a foreign helper without an owned shim"
  exit 1
fi
[[ "$(shasum -a 256 "$foreign_hooks" | awk '{print $1}')" == "$foreign_hooks_hash" ]]
[[ "$(shasum -a 256 "$foreign_installed_helper" | awk '{print $1}')" \
    == "$foreign_helper_hash" ]]

print "Hook installer smoke tests passed."
