# lokalise-sync

CLI tool to cherry-pick localization keys from Lokalise and merge them into existing `.strings` and `.stringsdict` files without overwriting unrelated keys. Useful in multi-developer projects with parallel feature branches, where full file downloads aren't an option.

## Requirements

- Python 3
- [jq](https://jqlang.github.io/jq/)
- [yq](https://github.com/mikefarah/yq)

## Install

```bash
brew install jq yq
git clone git@github.com:pkrll/lokalise-sync.git
cd lokalise-sync
chmod +x lokalise-sync.sh
ln -s "$(pwd)/lokalise-sync.sh" /usr/local/bin/lokalise-sync
```

## Setup

1. Set your Lokalise API token:
```bash
export LOKALISE_API_TOKEN="your-token-here"
```

2. Add a `.lokalise-sync.yml` config file to your project root:
```yaml
lokalise:
  project_id: "YOUR_PROJECT_ID"
  api_token_env: "LOKALISE_API_TOKEN" # env var name (not the token itself)

languages:
  - iso: "en"
    lproj: "en.lproj"
  - iso: "sv"
    lproj: "sv.lproj"

base_path: "path/to/Resources"

files:
  - lokalise_filename: "Localizable.strings"
    local_filename: "Localizable.strings"
    format: "strings"
  - lokalise_filename: "Localizable.stringsdict"
    local_filename: "Localizable.stringsdict"
    format: "stringsdict"
```

3. Run `lokalise-sync` from the project root.

## Usage

```bash
# Sync specific keys
lokalise-sync "login.title" "login.subtitle"

# Sync by tag
lokalise-sync --tag "sprint-42"

# Preview without modifying files
lokalise-sync --dry-run "some.key"

# Limit to specific languages
lokalise-sync --langs sv,en "some.key"

# Full sync
lokalise-sync
```

Run `lokalise-sync --help` for all options.

## Structure

```
lokalise-sync.sh          # CLI entry point — API calls, config, orchestration
.lokalise-sync.yml        # Config, lives in your project root (per-project)
lib/
  merge_strings.py        # .strings parsing, filtering, alphabetical merge
  merge_stringsdict.py    # .stringsdict plist merge via plistlib
```
