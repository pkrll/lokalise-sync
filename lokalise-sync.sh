#!/usr/bin/env zsh
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────

readonly LOKALISE_API_BASE="https://api.lokalise.com/api2/projects"
readonly VERSION="1.0.0"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_CONFIG_ERROR=1
readonly EXIT_MISSING_DEP=2
readonly EXIT_API_ERROR=3

# ─── Globals ──────────────────────────────────────────────────────────────────

CONFIG_FILE="./.lokalise-sync.yml"
DRY_RUN=false
BACKUP=false
VERBOSE=false
FILTER_FILE=""
TAG=""
TEMP_DIR=""

typeset -a KEY_NAMES=()
typeset -a LANG_OVERRIDES=()

# Config values (populated by load_config)
PROJECT_ID=""
API_TOKEN=""
BASE_PATH=""
EXPORT_EMPTY_AS="base"
PLACEHOLDER_FORMAT="ios"
REPLACE_BREAKS=true

typeset -a LANG_ISOS=()
typeset -a LANG_LPROJS=()
typeset -a FILE_LOKALISE_NAMES=()
typeset -a FILE_LOCAL_NAMES=()
typeset -a FILE_FORMATS=()

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info()    { printf "[INFO]  %s\n" "$*" }
log_success() { printf "[OK]    %s\n" "$*" }
log_warn()    { printf "[WARN]  %s\n" "$*" >&2 }
log_error()   { printf "[ERROR] %s\n" "$*" >&2 }
log_debug()   { $VERBOSE && printf "[DEBUG] %s\n" "$*" || true }

# ─── Help ─────────────────────────────────────────────────────────────────────

show_help() {
    cat <<'HELP'
lokalise-sync.sh — Download specific keys from Lokalise and merge into .strings/.stringsdict

USAGE:
    ./lokalise-sync.sh [OPTIONS] [KEY_NAMES...]

ARGUMENTS:
    KEY_NAMES...              Keys to download (omit for full sync).
                              Supports wildcards: "prefix_*" resolves via API.

OPTIONS:
    -c, --config FILE         Config file path (default: ./.lokalise-sync.yml)
    -t, --tag TAG             Download by Lokalise tag instead of key names
    -l, --langs LANG,...      Override languages (comma-separated ISO codes)
    -f, --file FILENAME       Only process this file mapping (by lokalise_filename)
    --dry-run                 Preview without modifying files
    --backup                  Create .bak backups before merging
    -v, --verbose             Debug logging
    -h, --help                Show this help
    --version                 Show version

EXAMPLES:
    ./lokalise-sync.sh "login.title" "login.subtitle"
    ./lokalise-sync.sh --tag "sprint-42"
    ./lokalise-sync.sh --dry-run --langs sv,en "onboarding.welcome"
    ./lokalise-sync.sh --backup -f "Localizable.strings" "settings.title"
    ./lokalise-sync.sh "login.*"
HELP
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit $EXIT_SUCCESS
                ;;
            --version)
                echo "lokalise-sync $VERSION"
                exit $EXIT_SUCCESS
                ;;
            -c|--config)
                [[ -z "${2:-}" ]] && { log_error "Missing value for $1"; exit $EXIT_CONFIG_ERROR; }
                CONFIG_FILE="$2"
                shift 2
                ;;
            -t|--tag)
                [[ -z "${2:-}" ]] && { log_error "Missing value for $1"; exit $EXIT_CONFIG_ERROR; }
                TAG="$2"
                shift 2
                ;;
            -l|--langs)
                [[ -z "${2:-}" ]] && { log_error "Missing value for $1"; exit $EXIT_CONFIG_ERROR; }
                LANG_OVERRIDES=(${(s:,:)2})
                shift 2
                ;;
            -f|--file)
                [[ -z "${2:-}" ]] && { log_error "Missing value for $1"; exit $EXIT_CONFIG_ERROR; }
                FILTER_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --backup)
                BACKUP=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit $EXIT_CONFIG_ERROR
                ;;
            *)
                KEY_NAMES+=("$1")
                shift
                ;;
        esac
    done
}

# ─── Dependency Check ─────────────────────────────────────────────────────────

check_dependencies() {
    local missing=()
    for cmd in curl jq yq python3 unzip; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_error "Install with: brew install ${missing[*]}"
        exit $EXIT_MISSING_DEP
    fi
    log_debug "All dependencies found"
}

# ─── Config Loading ───────────────────────────────────────────────────────────

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit $EXIT_CONFIG_ERROR
    fi

    PROJECT_ID=$(yq '.lokalise.project_id' "$CONFIG_FILE")
    local token_direct token_env_var
    token_direct=$(yq '.lokalise.api_token // ""' "$CONFIG_FILE")
    token_env_var=$(yq '.lokalise.api_token_env // ""' "$CONFIG_FILE")
    BASE_PATH=$(yq '.base_path' "$CONFIG_FILE")

    EXPORT_EMPTY_AS=$(yq '.download.export_empty_as // "base"' "$CONFIG_FILE")
    PLACEHOLDER_FORMAT=$(yq '.download.placeholder_format // "ios"' "$CONFIG_FILE")
    REPLACE_BREAKS=$(yq '.download.replace_breaks // true' "$CONFIG_FILE")

    # Resolve API token: direct value takes precedence over env var
    if [[ -n "$token_direct" && "$token_direct" != "null" ]]; then
        API_TOKEN="$token_direct"
        log_debug "Using api_token from config file"
    elif [[ -n "$token_env_var" && "$token_env_var" != "null" ]]; then
        API_TOKEN="${(P)token_env_var:-}"
        if [[ -z "$API_TOKEN" ]]; then
            log_error "Environment variable '$token_env_var' is not set or empty"
            exit $EXIT_CONFIG_ERROR
        fi
        log_debug "Using api_token from env var: $token_env_var"
    else
        log_error "Config must specify either lokalise.api_token or lokalise.api_token_env"
        exit $EXIT_CONFIG_ERROR
    fi

    # Load languages
    local lang_count
    lang_count=$(yq '.languages | length' "$CONFIG_FILE")
    for (( i = 0; i < lang_count; i++ )); do
        LANG_ISOS+=($(yq ".languages[$i].iso" "$CONFIG_FILE"))
        LANG_LPROJS+=($(yq ".languages[$i].lproj" "$CONFIG_FILE"))
    done

    # Load file mappings
    local file_count
    file_count=$(yq '.files | length' "$CONFIG_FILE")
    for (( i = 0; i < file_count; i++ )); do
        FILE_LOKALISE_NAMES+=($(yq ".files[$i].lokalise_filename" "$CONFIG_FILE"))
        FILE_LOCAL_NAMES+=($(yq ".files[$i].local_filename" "$CONFIG_FILE"))
        FILE_FORMATS+=($(yq ".files[$i].format" "$CONFIG_FILE"))
    done

    log_debug "Config loaded: project=$PROJECT_ID, languages=${LANG_ISOS[*]}, files=${FILE_LOKALISE_NAMES[*]}"
}

validate_config() {
    [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "null" ]] && {
        log_error "Config missing: lokalise.project_id"
        exit $EXIT_CONFIG_ERROR
    }
    [[ -z "$BASE_PATH" || "$BASE_PATH" == "null" ]] && {
        log_error "Config missing: base_path"
        exit $EXIT_CONFIG_ERROR
    }
    [[ ${#LANG_ISOS[@]} -eq 0 ]] && {
        log_error "Config missing: languages (need at least one)"
        exit $EXIT_CONFIG_ERROR
    }
    [[ ${#FILE_LOKALISE_NAMES[@]} -eq 0 ]] && {
        log_error "Config missing: files (need at least one)"
        exit $EXIT_CONFIG_ERROR
    }

    if [[ ! -d "$BASE_PATH" ]]; then
        log_error "base_path directory does not exist: $BASE_PATH"
        exit $EXIT_CONFIG_ERROR
    fi
}

# ─── Wildcard Resolution ─────────────────────────────────────────────────────

resolve_wildcards() {
    # Check if any key contains a wildcard
    local has_wildcard=false
    for key in "${KEY_NAMES[@]}"; do
        if [[ "$key" == *'*'* ]]; then
            has_wildcard=true
            break
        fi
    done

    if ! $has_wildcard; then
        log_debug "No wildcard patterns found, skipping key resolution"
        return
    fi

    # Separate exact keys from wildcard patterns
    local -a exact_keys=()
    local -a wildcard_patterns=()
    for key in "${KEY_NAMES[@]}"; do
        if [[ "$key" == *'*'* ]]; then
            wildcard_patterns+=("$key")
        else
            exact_keys+=("$key")
        fi
    done

    log_info "Resolving ${#wildcard_patterns[@]} wildcard pattern(s) via API..."

    # Fetch all key names from the project using cursor pagination
    local -a all_key_names=()
    local cursor="" page=1
    local url response_file header_file http_code key_count jq_output next_cursor
    local -a page_keys=()

    while true; do
        url="${LOKALISE_API_BASE}/${PROJECT_ID}/keys?limit=500&pagination=cursor&include_translations=0"
        if [[ -n "$cursor" ]]; then
            url="${url}&cursor=${cursor}"
        fi

        log_debug "Fetching keys page $page (url: $url)..."

        response_file=$(mktemp)
        header_file=$(mktemp)

        http_code=$(curl -s -w "%{http_code}" -o "$response_file" -D "$header_file" \
            -X GET \
            -H "x-api-token: $API_TOKEN" \
            -H "Accept: application/json" \
            "$url")

        if [[ "$http_code" -ne 200 ]]; then
            log_error "List Keys API request failed (HTTP $http_code)"
            log_error "Response: $(<"$response_file")"
            rm -f "$response_file" "$header_file"
            exit $EXIT_API_ERROR
        fi

        log_debug "Response body (first 500 chars): $(head -c 500 "$response_file")"

        # Skip empty pages
        key_count=$(jq '.keys | length' "$response_file")
        if [[ "$key_count" -eq 0 ]]; then
            rm -f "$response_file" "$header_file"
            break
        fi

        # Extract key names — handle both object and string key_name formats
        jq_output=$(jq -r '.keys[] | if (.key_name | type) == "object" then .key_name.ios else .key_name end' "$response_file" 2>&1) || {
            log_debug "jq extraction failed: $jq_output"
            rm -f "$response_file" "$header_file"
            break
        }

        page_keys=()
        if [[ -n "$jq_output" ]]; then
            page_keys=("${(@f)jq_output}")
        fi
        all_key_names+=("${page_keys[@]}")

        log_debug "Page $page: fetched ${#page_keys[@]} keys"

        # Read next cursor from response header
        next_cursor=$(grep -i 'X-Pagination-Next-Cursor' "$header_file" 2>/dev/null | sed 's/.*: *//;s/\r$//' || true)

        rm -f "$response_file" "$header_file"

        if [[ -z "$next_cursor" ]]; then
            break
        fi

        cursor="$next_cursor"
        (( page++ ))
    done

    log_info "Fetched ${#all_key_names[@]} total keys from project"

    # Match wildcard patterns against fetched keys
    local -a resolved_keys=()
    for pattern in "${wildcard_patterns[@]}"; do
        local match_count=0
        for name in "${all_key_names[@]}"; do
            if [[ "$name" == ${~pattern} ]]; then
                resolved_keys+=("$name")
                (( ++match_count ))
            fi
        done
        if [[ $match_count -eq 0 ]]; then
            log_warn "Pattern '$pattern' matched 0 keys"
        else
            log_info "Pattern '$pattern' matched $match_count key(s)"
        fi
    done

    # Combine exact keys with resolved wildcard keys
    KEY_NAMES=("${exact_keys[@]}" "${resolved_keys[@]}")

    if [[ ${#KEY_NAMES[@]} -eq 0 ]]; then
        log_error "No keys resolved from wildcard patterns — nothing to sync"
        exit $EXIT_CONFIG_ERROR
    fi

    log_info "Resolved to ${#KEY_NAMES[@]} total key(s)"
    log_debug "Resolved keys: ${KEY_NAMES[*]}"
}

# ─── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        log_debug "Cleaning up temp dir: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# ─── API Calls ────────────────────────────────────────────────────────────────

download_files() {
    TEMP_DIR=$(mktemp -d)
    log_debug "Temp directory: $TEMP_DIR"

    # Build request body
    local body
    body=$(jq -n \
        --arg format "strings" \
        --arg placeholder "$PLACEHOLDER_FORMAT" \
        --arg empty "$EXPORT_EMPTY_AS" \
        --argjson breaks "$REPLACE_BREAKS" \
        '{
            format: $format,
            original_filenames: true,
            directory_prefix: "%LANG_ISO%",
            placeholder_format: $placeholder,
            export_empty_as: $empty,
            replace_breaks: $breaks
        }')

    # Add filter_keys if key names provided (and no tag)
    if [[ ${#KEY_NAMES[@]} -gt 0 && -z "$TAG" ]]; then
        local keys_json
        keys_json=$(printf '%s\n' "${KEY_NAMES[@]}" | jq -R . | jq -s .)
        body=$(echo "$body" | jq --argjson keys "$keys_json" '. + {filter_keys: $keys}')
        log_info "Filtering by keys: ${KEY_NAMES[*]}"
    fi

    # Add include_tags if tag specified
    if [[ -n "$TAG" ]]; then
        body=$(echo "$body" | jq --arg tag "$TAG" '. + {include_tags: [$tag]}')
        log_info "Filtering by tag: $TAG"
    fi

    # Filter languages if overrides provided
    if [[ ${#LANG_OVERRIDES[@]} -gt 0 ]]; then
        local langs_json
        langs_json=$(printf '%s\n' "${LANG_OVERRIDES[@]}" | jq -R . | jq -s .)
        body=$(echo "$body" | jq --argjson langs "$langs_json" '. + {filter_langs: $langs}')
        log_info "Filtering by languages: ${LANG_OVERRIDES[*]}"
    fi

    log_debug "Request body: $body"

    # Call download endpoint
    local response http_code
    response=$(curl -s -w "%{http_code}" -o "${TEMP_DIR}/response_body.json" \
        -X POST \
        -H "x-api-token: $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${LOKALISE_API_BASE}/${PROJECT_ID}/files/download")

    http_code="$response"
    response=$(<"${TEMP_DIR}/response_body.json")

    if [[ "$http_code" -ne 200 ]]; then
        log_error "API request failed (HTTP $http_code)"
        log_error "Response: $response"
        exit $EXIT_API_ERROR
    fi

    local bundle_url
    bundle_url=$(echo "$response" | jq -r '.bundle_url // empty')
    if [[ -z "$bundle_url" ]]; then
        log_error "No bundle_url in API response"
        log_error "Response: $response"
        exit $EXIT_API_ERROR
    fi

    log_debug "Bundle URL: $bundle_url"

    # Download and extract bundle
    local zip_path="${TEMP_DIR}/bundle.zip"
    local dl_http_code
    dl_http_code=$(curl -s -w "%{http_code}" -o "$zip_path" "$bundle_url")

    if [[ "$dl_http_code" -ne 200 ]]; then
        log_error "Failed to download bundle (HTTP $dl_http_code)"
        exit $EXIT_API_ERROR
    fi

    unzip -qo "$zip_path" -d "${TEMP_DIR}/extracted"
    log_success "Bundle downloaded and extracted"
    log_debug "Contents: $(ls -R "${TEMP_DIR}/extracted" 2>/dev/null)"
}

# ─── Resolve path to lib/ relative to the script ─────────────────────────────

SCRIPT_DIR="${0:A:h}"
LIB_DIR="${SCRIPT_DIR}/lib"

# ─── File Merging ─────────────────────────────────────────────────────────────

merge_strings_file() {
    local source_file="$1"
    local target_file="$2"
    shift 2
    local -a keys_to_keep=("$@")

    if [[ ! -f "$source_file" ]]; then
        log_debug "Source strings file not found: $source_file"
        return
    fi

    local -a args=("$source_file" "$target_file")
    $DRY_RUN && args+=(--dry-run)
    $BACKUP && args+=(--backup)

    if [[ ${#keys_to_keep[@]} -gt 0 ]]; then
        local keys_json
        keys_json=$(printf '%s\n' "${keys_to_keep[@]}" | jq -R . | jq -s '.')
        args+=(--keys-json "$keys_json")
    fi

    python3 "${LIB_DIR}/merge_strings.py" "${args[@]}"
}

merge_stringsdict_file() {
    local source_file="$1"
    local target_file="$2"
    shift 2
    local -a keys_to_keep=("$@")

    if [[ ! -f "$source_file" ]]; then
        log_debug "Source stringsdict not found: $source_file"
        return
    fi

    local -a args=("$source_file" "$target_file")
    $DRY_RUN && args+=(--dry-run)
    $BACKUP && args+=(--backup)

    if [[ ${#keys_to_keep[@]} -gt 0 ]]; then
        local keys_json
        keys_json=$(printf '%s\n' "${keys_to_keep[@]}" | jq -R . | jq -s '.')
        args+=(--keys-json "$keys_json")
    fi

    python3 "${LIB_DIR}/merge_stringsdict.py" "${args[@]}"
}

# ─── Main Processing ─────────────────────────────────────────────────────────

process_files() {
    local extracted_dir="${TEMP_DIR}/extracted"

    # Determine which languages to process
    local -a active_isos=()
    local -a active_lprojs=()

    if [[ ${#LANG_OVERRIDES[@]} -gt 0 ]]; then
        for override in "${LANG_OVERRIDES[@]}"; do
            for (( i = 1; i <= ${#LANG_ISOS[@]}; i++ )); do
                if [[ "${LANG_ISOS[$i]}" == "$override" ]]; then
                    active_isos+=("${LANG_ISOS[$i]}")
                    active_lprojs+=("${LANG_LPROJS[$i]}")
                    break
                fi
            done
        done
    else
        active_isos=("${LANG_ISOS[@]}")
        active_lprojs=("${LANG_LPROJS[@]}")
    fi

    # Process each language
    for (( li = 1; li <= ${#active_isos[@]}; li++ )); do
        local iso="${active_isos[$li]}"
        local lproj="${active_lprojs[$li]}"

        log_info "Processing language: $iso ($lproj)"

        # Process each file mapping
        for (( fi_idx = 1; fi_idx <= ${#FILE_LOKALISE_NAMES[@]}; fi_idx++ )); do
            local lok_name="${FILE_LOKALISE_NAMES[$fi_idx]}"
            local local_name="${FILE_LOCAL_NAMES[$fi_idx]}"
            local format="${FILE_FORMATS[$fi_idx]}"

            # Skip if --file filter is active and doesn't match
            if [[ -n "$FILTER_FILE" && "$lok_name" != "$FILTER_FILE" ]]; then
                continue
            fi

            local downloaded_file="${extracted_dir}/${iso}/${lok_name}"
            local target_file="${BASE_PATH}/${lproj}/${local_name}"

            if [[ ! -f "$downloaded_file" ]]; then
                log_warn "Downloaded file not found: $downloaded_file"
                continue
            fi

            log_debug "Processing: $downloaded_file -> $target_file"

            if [[ "$format" == "strings" ]]; then
                merge_strings_file "$downloaded_file" "$target_file" "${KEY_NAMES[@]}"
            elif [[ "$format" == "stringsdict" ]]; then
                merge_stringsdict_file "$downloaded_file" "$target_file" "${KEY_NAMES[@]}"
            fi
        done
    done
}

# ─── Entry Point ──────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    log_info "lokalise-sync v${VERSION}"
    $DRY_RUN && log_info "Dry run mode enabled"

    check_dependencies
    load_config
    validate_config
    resolve_wildcards

    if [[ ${#KEY_NAMES[@]} -eq 0 && -z "$TAG" ]]; then
        log_info "No keys or tag specified — performing full sync"
    fi

    download_files
    process_files

    log_success "Sync complete"
}

main "$@"
