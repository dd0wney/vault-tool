# vault-tool

CLI for managing LUKS-encrypted client engagement vaults with Yubikey authentication.

## Installation

```bash
ln -s "$(pwd)/vault" ~/bin/vault
```

Ensure `~/bin` is in your PATH.

## Dependencies

- `cryptsetup` - LUKS encryption
- `systemd-cryptenroll` - Yubikey enrollment
- `op` - 1Password CLI (for `vault new`)

## Usage

```bash
vault open <client>    # Open and mount (tap Yubikey when prompted)
vault close <client>   # Unmount and close
vault status <client>  # Check if open
vault list             # List available vaults
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_DIR` | `~/.vaults` | Where `.img` files are stored |
| `MOUNT_BASE` | `/mnt` | Parent directory for mount points |
| `OP_VAULT` | `Work` | 1Password vault for recovery passphrases |

An environment variable overrides the config file, and the config file
overrides the default. The config file is
`${XDG_CONFIG_HOME:-~/.config}/vault-tool/config`.

```bash
vault config                         # show current values and the config file
vault config set VAULT_DIR ~/vaults  # set a value in the config file
```

## Creating a new vault

```bash
vault new clientname        # creates 500MB vault
vault new clientname 1G     # creates 1GB vault
```

This will:
1. Generate a secure recovery passphrase
2. Store it in 1Password (item: `clientname-vault-recovery`)
3. Create and format the LUKS container
4. Enroll your Yubikey

Requires: 1Password CLI (`op`) authenticated. If any step fails, `vault new`
removes the image and the 1Password item.

A vault that an older version created has a top directory owned by root. To
write to it without sudo, open it and run:

```bash
sudo chown "$(id -u):$(id -g)" /mnt/clientname
```

## Recovery without a Yubikey

`vault open` accepts only the Yubikey, so run `cryptsetup` directly:

```bash
op read "op://Work/clientname-vault-recovery/password" \
    | sudo cryptsetup open ~/.vaults/clientname.img clientname-vault --key-file=-
sudo mount /dev/mapper/clientname-vault /mnt/clientname
```

Do not paste the passphrase at a `cryptsetup` prompt. `vault new` passes it with
a trailing newline, and with `--key-file=-` that newline is part of the key, so
the pasted passphrase does not match. If a vault was not made by `vault new`
and the command above fails, try `op read -n`, which omits the newline.

`vault close clientname` closes a recovered vault as usual. Replace `Work` and
the paths if you changed the configuration.

## Tests

```bash
tests/run.sh
```

The tests need no root, Yubikey, or 1Password account, because fake commands on
`PATH` replace `sudo`, `cryptsetup`, `op`, and the other system tools. They
therefore do not prove that the real tools accept the arguments. Use the manual
test for that.

## Manual test

Run this after a change to `vault new`, `vault open`, or `vault close`. It needs
the Yubikey, its PIN, sudo, and a signed-in `op`. Use a client name that does not
exist.

```bash
vault new smoke-test 20M                 # touch the Yubikey when prompted
vault open smoke-test                    # touch the Yubikey when prompted
touch /mnt/smoke-test/write-check        # must succeed without sudo
vault status smoke-test                  # must report OPEN
vault close smoke-test
vault status smoke-test                  # must report CLOSED

# Recovery path: must unlock without the Yubikey
op read "op://Work/smoke-test-vault-recovery/password" \
    | sudo cryptsetup open "$(vault config | awk '/VAULT_DIR/ { print $2; exit }')/smoke-test.img" \
        smoke-test-vault --key-file=-
vault close smoke-test

# Remove the test vault
rm "$(vault config | awk '/VAULT_DIR/ { print $2; exit }')/smoke-test.img"
op item delete smoke-test-vault-recovery --vault=Work
sudo rmdir /mnt/smoke-test
```

## File layout

```
~/.vaults/
├── eql.img
├── otherclient.img
└── ...

/mnt/
├── eql/          # mount point when open
└── otherclient/
```
