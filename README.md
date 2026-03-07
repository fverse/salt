# Salt

Branch-aware Git submodule alternative.

Salt automatically syncs your submodules to the correct branch based on your current working branch. Define branch mappings once in a `Saltfile`.

## Install

Run the following commands for your OS:

```sh
# macOS Apple Silicon
curl -LO https://github.com/fverse/salt/releases/latest/download/salt-aarch64-macos.tar.gz
tar -xzf salt-aarch64-macos.tar.gz
sudo mv salt /usr/local/bin/

# macOS Intel
curl -LO https://github.com/fverse/salt/releases/latest/download/salt-x86_64-macos.tar.gz
tar -xzf salt-x86_64-macos.tar.gz
sudo mv salt /usr/local/bin/

# Linux x86_64
curl -LO https://github.com/fverse/salt/releases/latest/download/salt-x86_64-linux.tar.gz
tar -xzf salt-x86_64-linux.tar.gz
sudo mv salt /usr/local/bin/

# Linux ARM64
curl -LO https://github.com/fverse/salt/releases/latest/download/salt-aarch64-linux.tar.gz
tar -xzf salt-aarch64-linux.tar.gz
sudo mv salt /usr/local/bin/
```

Or download the prebuilt binary from [Releases](https://github.com/fverse/salt/releases):

### Build from source

Requires Zig 0.14.0+.

```sh
zig build --release=safe
```

The binary will be at `zig-out/bin/salt`.

## Quick Start

```sh
# Initialize Salt in your repo
salt init

# Add a submodule with branch mappings
salt add https://github.com/user/repo.git libs/repo

```

## Saltfile Format

```ini
[submodule "mylib"]
    path = libs/mylib
    url = https://github.com/user/mylib.git
    default_branch = main
    branches = {
        main -> main
        dev -> develop
        release -> release
    }
```

Branch mappings use `parent_branch -> submodule_branch` syntax. When you're on `dev` in the parent repo, Salt checks out the `develop` branch in the submodule. Unmapped branches fall back to `default_branch`.

## Commands

| Command            | Description                               |
| ------------------ | ----------------------------------------- |
| `init`             | Initialize a Saltfile in the current repo |
| `add <url> [path]` | Add a submodule                           |
| `resolve [name]`   | Clone and set up dependencies             |
| `sync [name]`      | Sync submodules to the correct branch     |
| `pull [name]`      | Pull latest changes on current branches   |
| `push [name]`      | Push submodule changes to remotes         |
| `status`           | Show status of all submodules             |
| `remove <name>`    | Remove a submodule                        |

Global flags: `--quiet`, `--verbose`, `--help`, `--version`

## License

MIT
