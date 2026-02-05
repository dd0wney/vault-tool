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

Environment variables (with defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_DIR` | `~/.vaults` | Where `.img` files are stored |
| `MOUNT_BASE` | `/mnt` | Parent directory for mount points |
| `OP_VAULT` | `Work` | 1Password vault for recovery passphrases |

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

Requires: 1Password CLI (`op`) authenticated.

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
