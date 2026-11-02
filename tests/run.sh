#!/bin/bash
# Tests for ./vault that need no root, YubiKey, or 1Password account.
#
# Every privileged or external command is replaced by a logging fake on PATH,
# so a test asserts on what vault asked the system to do. FAKE_FAIL takes a glob
# matched against "<command> <args>" and makes the matching call exit 1, which
# is how a test reaches the failure paths real tools rarely produce on demand.
#
# Deliberately no `set -e`: tests expect commands to fail.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT="$ROOT/vault"

# vault tests /dev/mapper directly, so this name must not match a real device.
CLIENT="vtt-acme"
MAPPER="/dev/mapper/${CLIENT}-vault"

make_fake() {
    local name="$1"
    cat >"$SANDBOX/bin/$name" <<EOF
#!/bin/bash
shopt -s extglob
printf '%s\n' "$name \$*" >>"\$FAKE_LOG"
case "$name \$*" in
    \${FAKE_FAIL:-__no_failure__}) exit 1 ;;
    "op read "*) echo test-passphrase ;;
esac
EOF
    chmod +x "$SANDBOX/bin/$name"
}

setup_sandbox() {
    SANDBOX="$1"
    mkdir -p "$SANDBOX"/{bin,home,vaults,mnt,config}

    local name
    for name in op cryptsetup mount umount mkfs.ext4 systemd-cryptenroll; do
        make_fake "$name"
    done

    # The fake runs the command, so `sudo cryptsetup` reaches the fake cryptsetup
    # and `sudo sh -c` really creates the mount point inside the sandbox.
    cat >"$SANDBOX/bin/sudo" <<'EOF'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$FAKE_LOG"
exec "$@"
EOF
    chmod +x "$SANDBOX/bin/sudo"

    export FAKE_LOG="$SANDBOX/calls.log"
    export HOME="$SANDBOX/home"
    export VAULT_DIR="$SANDBOX/vaults"
    export MOUNT_BASE="$SANDBOX/mnt"
    export OP_VAULT="Test"
    export XDG_CONFIG_HOME="$SANDBOX/config"
    IMG="$VAULT_DIR/$CLIENT.img"
    CONFIG="$XDG_CONFIG_HOME/vault-tool/config"
    : >"$FAKE_LOG"
}

run_vault() {
    VAULT_STATUS=0
    PATH="$SANDBOX/bin:$PATH" "$VAULT" "$@" >"$SANDBOX/output" 2>&1 || VAULT_STATUS=$?
}

fail() {
    echo "  $*"
    echo "  --- vault output ---"
    sed 's/^/  | /' "$SANDBOX/output" 2>/dev/null
    echo "  --- fake calls ---"
    sed 's/^/  | /' "$FAKE_LOG" 2>/dev/null
    exit 1
}

assert_status() {
    [[ "$VAULT_STATUS" == "$1" ]] || fail "expected exit status $1, got $VAULT_STATUS"
}

assert_failed() {
    [[ "$VAULT_STATUS" != 0 ]] || fail "expected a non-zero exit status"
}

assert_called() {
    grep -Fq -- "$1" "$FAKE_LOG" || fail "expected a call containing: $1"
}

assert_not_called() {
    ! grep -Fq -- "$1" "$FAKE_LOG" || fail "expected no call containing: $1"
}

assert_exists() {
    [[ -e "$1" ]] || fail "expected file to exist: $1"
}

assert_missing() {
    [[ ! -e "$1" ]] || fail "expected file to be absent: $1"
}

assert_output_has() {
    grep -Fq -- "$1" "$SANDBOX/output" || fail "expected output containing: $1"
}

# --- vault new ---

test_new_creates_private_image_and_enrols_yubikey() {
    run_vault new "$CLIENT" 10M
    assert_status 0
    assert_exists "$IMG"
    [[ "$(stat -c '%a' "$IMG")" == 600 ]] || fail "expected image mode 600"
    assert_called "cryptsetup luksFormat $IMG"
    assert_called "systemd-cryptenroll $IMG"
}

test_new_makes_user_the_owner_of_the_file_system() {
    run_vault new "$CLIENT" 10M
    assert_status 0
    assert_called "mkfs.ext4 -q -E root_owner=$(id -u):$(id -g) $MAPPER"
}

test_new_gives_enrolment_the_passphrase_through_a_real_path() {
    # systemd-cryptenroll treats --unlock-key-file=- as a file named "-".
    run_vault new "$CLIENT" 10M
    assert_status 0
    assert_called "--unlock-key-file=/dev/stdin"
}

test_new_rejects_invalid_client_name() {
    run_vault new '../escape' 10M
    assert_failed
    assert_output_has "Invalid client name"
    assert_not_called "op item create"
}

test_new_removes_image_when_op_item_create_fails() {
    FAKE_FAIL='op item create*' run_vault new "$CLIENT" 10M
    assert_failed
    assert_missing "$IMG"
    assert_not_called "op item delete"
}

test_new_can_retry_after_op_item_create_fails() {
    FAKE_FAIL='op item create*' run_vault new "$CLIENT" 10M
    run_vault new "$CLIENT" 10M
    assert_status 0
    assert_exists "$IMG"
}

test_new_removes_image_and_op_item_when_luks_format_fails() {
    FAKE_FAIL='cryptsetup luksFormat*' run_vault new "$CLIENT" 10M
    assert_failed
    assert_missing "$IMG"
    assert_called "op item delete ${CLIENT}-vault-recovery"
}

test_new_removes_image_and_op_item_when_enrolment_fails() {
    FAKE_FAIL='systemd-cryptenroll*' run_vault new "$CLIENT" 10M
    assert_failed
    assert_missing "$IMG"
    assert_called "op item delete ${CLIENT}-vault-recovery"
}

test_new_warns_when_op_item_cannot_be_removed() {
    FAKE_FAIL='@(cryptsetup luksFormat*|op item delete*)' run_vault new "$CLIENT" 10M
    assert_failed
    assert_output_has "${CLIENT}-vault-recovery"
    assert_output_has "Warning"
}

test_new_leaves_existing_vault_untouched() {
    echo existing-data >"$IMG"
    run_vault new "$CLIENT" 10M
    assert_failed
    assert_output_has "already exists"
    [[ "$(cat "$IMG")" == existing-data ]] || fail "existing vault was changed"
    assert_not_called "op item"
}

test_new_keeps_everything_on_success() {
    run_vault new "$CLIENT" 10M
    assert_status 0
    assert_exists "$IMG"
    assert_not_called "op item delete"
    ! grep -Fq "Cleaning up" "$SANDBOX/output" || fail "cleanup ran after success"
}

# --- vault open ---

test_open_unlocks_with_token_only_then_mounts() {
    : >"$IMG"
    run_vault open "$CLIENT"
    assert_status 0
    assert_called "cryptsetup open --token-only $IMG ${CLIENT}-vault"
    assert_called "mount $MAPPER $MOUNT_BASE/$CLIENT"
}

test_open_refuses_symlinked_mount_point() {
    : >"$IMG"
    ln -s "$SANDBOX/home" "$MOUNT_BASE/$CLIENT"
    run_vault open "$CLIENT"
    assert_failed
    assert_called "cryptsetup close ${CLIENT}-vault"
    assert_not_called "mount $MAPPER"
}

test_open_closes_mapper_when_mount_fails() {
    : >"$IMG"
    FAKE_FAIL='mount *' run_vault open "$CLIENT"
    assert_failed
    assert_called "cryptsetup close ${CLIENT}-vault"
}

test_open_keeps_mapper_when_mount_succeeds() {
    : >"$IMG"
    run_vault open "$CLIENT"
    assert_status 0
    assert_not_called "cryptsetup close"
}

# --- vault config ---

test_config_set_replaces_key_and_keeps_others() {
    mkdir -p "$(dirname "$CONFIG")"
    printf 'CONFIG_OP_VAULT="Keep"\nCONFIG_MOUNT_BASE="/old"\n' >"$CONFIG"
    run_vault config set MOUNT_BASE /new
    assert_status 0
    grep -Fxq 'CONFIG_OP_VAULT="Keep"' "$CONFIG" || fail "lost CONFIG_OP_VAULT"
    grep -Fxq 'CONFIG_MOUNT_BASE="/new"' "$CONFIG" || fail "new value missing"
    ! grep -Fq '/old' "$CONFIG" || fail "old value kept"
}

test_config_set_stops_when_grep_reports_an_error() {
    mkdir -p "$(dirname "$CONFIG")"
    printf 'CONFIG_OP_VAULT="Keep"\n' >"$CONFIG"
    printf '#!/bin/bash\nexit 2\n' >"$SANDBOX/bin/grep"
    chmod +x "$SANDBOX/bin/grep"

    run_vault config set MOUNT_BASE /new

    assert_failed
    assert_output_has "Failed to read config file"
    [[ "$(cat "$CONFIG")" == 'CONFIG_OP_VAULT="Keep"' ]] || fail "config file changed"
    [[ "$(find "$(dirname "$CONFIG")" -type f | wc -l)" == 1 ]] || fail "temporary file left behind"
}

test_config_set_accepts_file_with_only_that_key() {
    mkdir -p "$(dirname "$CONFIG")"
    printf 'CONFIG_MOUNT_BASE="/old"\n' >"$CONFIG"
    run_vault config set MOUNT_BASE /new
    assert_status 0
    [[ "$(cat "$CONFIG")" == 'CONFIG_MOUNT_BASE="/new"' ]] || fail "value not replaced"
}

# --- runner ---

main() {
    local tests failures=0 count=0 name sandbox
    tests="$(declare -F | awk '$3 ~ /^test_/ { print $3 }')"

    for name in $tests; do
        count=$((count + 1))
        sandbox="$(mktemp -d)"
        if (setup_sandbox "$sandbox"; "$name"); then
            echo "ok   $name"
        else
            echo "FAIL $name"
            failures=$((failures + 1))
        fi
        rm -rf "$sandbox"
    done

    # A runner that found no tests must not look like a passing run.
    if ((count == 0)); then
        echo "No tests found" >&2
        exit 1
    fi

    echo "$((count - failures))/$count passed"
    ((failures == 0))
}

main "$@"
