# Salt

Branch-aware Git submodule alternative.

Salt automatically syncs your submodules to the correct branch based on your current working branch. Define branch mappings once in a `Saltfile`, and Salt handles the rest.

## Install

Download a prebuilt binary from [Releases](https://github.com/fverse/salt/releases):

```sh
# Example for macOS ARM
tar -xzf salt-aarch64-macos.tar.gz
sudo mv salt /usr/local/bin/
```

Available targets: `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos`.

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
