# sug.sh

`sug.sh` is a Shell token autosuggestion integration layer.

## Overview

It provides a lightweight, POSIX-compliant script for ranking and
suggesting candidate tokens based on frequency and similarity for
interactive Bash shells.

## Usage

Source the script in an interactive Bash session:

```bash
. ./sug.sh -m /path/to/tokens.txt [options]
```

## Parameters Reference

| Flag | Description | Default |
| :--- | :--- | :--- |
| `--map`, `-m` | Path to token map file. Can be repeated | `N/A` |
| `--limit`, `-n` | Maximum candidate count | `8` |
| `--threshold`, `-t` | Similarity threshold (0.0 to 1.0) | `0.3` |
| `--help`, `-h` | Show help and usage | `false` |

## Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `SUG_MAPS` | Space-separated list of candidate map files | `N/A` |
| `SUG_LIMIT` | Maximum candidate count | `8` |
| `SUG_THRESHOLD` | Similarity threshold (0.0 to 1.0) | `0.3` |
| `SUG_MIN` | Minimum token length for suggestions | `3` |

---

**Author:** KaisarCode

**Email:** <kaisar@kaisarcode.com>

**Website:** [https://kaisarcode.com](https://kaisarcode.com)

**License:** [GNU GPL v3.0](https://www.gnu.org/licenses/gpl-3.0.html)

© 2026 KaisarCode
