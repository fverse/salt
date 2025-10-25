# Salt

Branch-aware Git submodule alternative

## Overview

Salt is a tool that makes working with shared dependencies less painful. It automatically syncs your submodules to the right branch based on your current working branch, so you don't have to manually manage them every time you switch contexts.

Define branch mappings once in `salt.conf`, and Salt handles the rest—keeping your dependencies in sync without the usual submodule headaches.

Provides a simple CLI to add, sync, and manage submodules that follow your branching workflow. Whether you're on `dev`, `release`, or a feature branch, Salt ensures your submodules are always on the correct corresponding branch.
