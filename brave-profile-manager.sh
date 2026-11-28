#!/usr/bin/env bash
#
# brave-profile-manager.sh
#
# Add or remove fully independent Brave browser profiles as .desktop launchers,
# based on the approach described here:
# https://gist.github.com/pannal/d398ee9801a8c6d0e44b1027af193610
#
# Design notes:
#   - Paths come from the XDG Base Directory Specification, not hardcoded
#     distro locations.
#   - MIME types, icons and Brave variants are read from the registrations
#     already installed on this machine. No desktop-environment name, package
#     manager, terminal emulator or dialog tool is assumed.
#   - Each profile gets a versioned marker, a MIME registration and a saved,
#     self-contained uninstaller, so it behaves like an independently installed
#     browser app and can be removed without affecting other profiles.
#
# ADD:
#   - detects installed Brave variants (stable, Beta, Nightly, Origin and
#     its Beta/Nightly, snap, flatpak, plus anything else found on PATH)
#   - creates a separate --user-data-dir per profile (so KDE/GNOME treat
#     each as its own app instead of grouping windows together)
#   - extracts the icon from the selected variant itself and draws a
#     colored dot (your choice of color) in the top-right corner
#   - writes a .desktop launcher named exactly what you typed
#   - registers the variant's MIME types so the profile appears in
#     default-app and "Open with" lists; it never sets you as the default
#   - saves a per-profile uninstaller used by menu option 2 and the
#     right-click action; no separate uninstall launcher is added
#
# REMOVE:
#   - lists launchers previously created by this script
#   - always removes the launcher, icon, MIME registrations and saved
#     uninstaller (and any legacy uninstall launcher from older versions)
#   - only deletes the profile's browsing data if you explicitly type
#     "yes" when asked, per profile
#
# Requires: bash, coreutils, ImageMagick (convert/magick + identify) for
# the ADD path. REMOVE needs no extra dependencies.

set -uo pipefail

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CONFIG_DIRS="${XDG_CONFIG_DIRS:-/etc/xdg}"
XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

APPS_DIR="$XDG_DATA_HOME/applications"
ICONS_DIR="$XDG_DATA_HOME/icons"
SUPPORT_DIR="$XDG_DATA_HOME/brave-profile-manager"
MARKER='Brave Profile Manager'
FORMAT_VERSION='2'
PROFILE_ROLE='profile'
UNINSTALL_ROLE='uninstall'
CLASS_PREFIX='brave'
BACKUP_DIR=''
IM_CONVERT=''

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

die() { echo "Error: $*" >&2; exit 1; }
info()  { echo -e "\033[1;34m==>\033[0m $*"; }
warn()  { echo -e "\033[1;33m!!\033[0m $*" >&2; }
ok()    { echo -e "\033[1;32m✓\033[0m $*"; }

ask() {
    # ask "Prompt text" default_value -> echoes the answer
    local prompt="$1" default="${2:-}" answer
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " answer
        echo "${answer:-$default}"
    else
        read -r -p "$prompt: " answer
        echo "$answer"
    fi
}

ask_required() {
    local prompt="$1" answer
    while true; do
        read -r -p "$prompt: " answer
        [[ -n "$answer" ]] && { echo "$answer"; return; }
        warn "This can't be empty, try again."
    done
}

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-' | sed 's/-\+/-/g; s/^-//; s/-$//'
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

shell_quote() {
    local s="$1"
    s=${s//\'/\'\\\'\'}
    printf "'%s'" "$s"
}

sed_repl() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

desk_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g'; }

backup_file() {
    local f="$1" dest
    [[ -e "$f" ]] || return 0
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="$SUPPORT_DIR/backups/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
    fi
    dest="$BACKUP_DIR/$(printf '%s' "$f" | tr '/' '_')"
    [[ -e "$dest" ]] || cp -p -- "$f" "$dest"
}

# XDG application/icon directories, plus the standard export locations that
# applications place outside XDG_DATA_DIRS. They are probed, not assumed.
app_dirs() {
    local d out=()
    out+=("$APPS_DIR")
    IFS=: read -ra _xdg_data_dirs <<< "$XDG_DATA_DIRS"
    for d in "${_xdg_data_dirs[@]:-}"; do
        [[ -n "$d" ]] && out+=("${d%/}/applications")
    done
    out+=(
        "$XDG_DATA_HOME/flatpak/exports/share/applications"
        "/var/lib/flatpak/exports/share/applications"
        "/var/lib/snapd/desktop/applications"
    )
    for d in "${out[@]}"; do
        [[ -d "$d" ]] && printf '%s\n' "$d"
    done | awk '!seen[$0]++'
}

icon_roots() {
    local d out=()
    out+=("$ICONS_DIR" "$XDG_DATA_HOME/icons")
    IFS=: read -ra _xdg_data_dirs <<< "$XDG_DATA_DIRS"
    for d in "${_xdg_data_dirs[@]:-}"; do
        [[ -n "$d" ]] && out+=("${d%/}/icons")
    done
    while IFS= read -r d; do
        out+=("${d%/applications}/icons")
    done < <(app_dirs)
    out+=(
        "$XDG_DATA_HOME/flatpak/exports/share/icons"
        "$XDG_DATA_HOME/snap"
        "/var/lib/flatpak/exports/share/icons"
        "/var/lib/snapd/desktop/icons"
    )
    for d in "${out[@]}"; do
        [[ -d "$d" ]] && printf '%s\n' "$d"
    done | awk '!seen[$0]++'
}

desktop_files() {
    local d
    for d in $(app_dirs); do
        find "$d" -maxdepth 1 -type f -name '*.desktop' -print 2>/dev/null
    done | sort -u
}

desk_field() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 0
    line=$(grep -m1 "^${key}=" "$file" 2>/dev/null | head -n1 | tr -d '\r')
    printf '%s' "${line#*=}"
}

brave_desktop_files() {
    local f name exec_line
    while IFS= read -r f; do
        [[ -n "$(desk_field "$f" X-BPM-Marker)" ]] && continue
        name=$(desk_field "$f" Name)
        exec_line=$(desk_field "$f" Exec)
        if [[ "$name" == *[Bb]rave* || "$exec_line" == *brave* ]]; then
            printf '%s\n' "$f"
        fi
    done < <(desktop_files)
}

desktop_for_command() {
    local bin="$1" target first try name f best='' best_mimes=0 mimes
    target=$(basename "${bin%% *}"); target=${target//\"/}
    while IFS= read -r f; do
        # Generated profile entries are not sources: they are copies of Brave's
        # registration and would otherwise win ties on path ordering.
        [[ -n "$(desk_field "$f" X-BPM-Marker)" ]] && continue
        first=$(desk_field "$f" Exec); first=${first%% *}; first=${first//\"/}
        first=$(basename "$first")
        try=$(desk_field "$f" TryExec); try=$(basename "$try")
        name=$(desk_field "$f" Name)
        local match=0
        [[ "$first" == "$target" || "$try" == "$target" ]] && match=1
        [[ "$target" == flatpak && "$name" == *[Bb]rave* ]] && match=1
        (( match )) || continue
        mimes=$(desk_field "$f" MimeType)
        local count=0
        [[ -n "$mimes" ]] && count=$(printf '%s' "$mimes" | tr ';' '\n' | grep -c .)
        if (( count > best_mimes )); then best="$f"; best_mimes=$count; fi
    done < <(desktop_files)
    printf '%s' "$best"
}

mimes_from_desktop() {
    local f="$1" entry m seen=''
    [[ -f "$f" ]] || return 0
    entry=$(desk_field "$f" MimeType)
    [[ -n "$entry" ]] || return 0
    printf '%s' "$entry" | tr ';' '\n' | while IFS= read -r m; do
        m=$(printf '%s' "$m" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')
        [[ -z "$m" ]] && continue
        [[ ";$seen;" == *";$m;"* ]] && continue
        seen+=";$m"
        printf '%s\n' "$m"
    done
}

all_brave_mimes() {
    local f
    while IFS= read -r f; do
        mimes_from_desktop "$f"
    done < <(brave_desktop_files) | awk '!seen[$0]++'
}

# XDG mimeapps.list lookup order. Only user-writable files are considered;
# desktop-specific names are derived from XDG_CURRENT_DESKTOP components.
mimeapps_paths() {
    local c p out=() parts=()
    out+=("$XDG_CONFIG_HOME/mimeapps.list"
          "$XDG_DATA_HOME/applications/mimeapps.list"
          "$XDG_DATA_HOME/applications/defaults.list")
    IFS=: read -ra parts <<< "${XDG_CURRENT_DESKTOP:-}"
    for p in "${parts[@]:-}"; do
        c=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]'); c=${c#x-}
        [[ -n "$c" ]] && out+=("$XDG_CONFIG_HOME/$c-mimeapps.list"
                               "$XDG_DATA_HOME/applications/$c-mimeapps.list")
    done
    for p in "${out[@]}"; do printf '%s\n' "$p"; done | awk '!seen[$0]++'
}

mimeapps_add_associations() {
    local file="$1" id="$2"; shift 2
    local mimes_file tmp
    mimes_file=$(mktemp)
    printf '%s\n' "$@" > "$mimes_file"
    [[ -e "$file" ]] || : > "$file"
    backup_file "$file"
    tmp=$(mktemp)
    awk -v id="$id" -v mimesfile="$mimes_file" '
        BEGIN {
            while ((getline m < mimesfile) > 0) {
                gsub(/\r/, "", m)
                if (m != "" && !wanted[m]++) want[++nwant] = m
            }
        }
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        /^\[/ {
            sec = $0; gsub(/\r/, "", sec)
            if (added && !ins) ins = NR
            if (sec == "[Added Associations]") added = 1
            lines[NR] = $0; next
        }
        {
            line = $0
            if (added && sec == "[Added Associations]" && line ~ /^[^#;=\r][^=\r]*=/) {
                eq = index(line, "=")
                key = trim(substr(line, 1, eq - 1))
                val = substr(line, eq + 1)
                if (key in wanted) {
                    found = 0; out = ""; rest = val
                    while ((p = index(rest, ";")) > 0) {
                        tok = substr(rest, 1, p - 1); rest = substr(rest, p + 1)
                        if (trim(tok) == id) found = 1
                        out = out tok ";"
                    }
                    if (rest != "") {
                        if (trim(rest) == id) found = 1
                        out = out rest ";"
                    }
                    if (!found) out = out id ";"
                    line = key "=" out
                    done[key] = 1
                }
            }
            lines[NR] = line
        }
        END {
            if (!added) {
                print "[Added Associations]"
                for (i = 1; i <= nwant; i++) print want[i] "=" id ";"
                exit
            }
            if (!ins) ins = NR + 1
            for (i = 1; i <= NR; i++) {
                if (i == ins) {
                    for (j = 1; j <= nwant; j++)
                        if (!(want[j] in done)) print want[j] "=" id ";"
                }
                print lines[i]
            }
            if (ins > NR) {
                for (j = 1; j <= nwant; j++)
                    if (!(want[j] in done)) print want[j] "=" id ";"
            }
        }
    ' "$file" > "$tmp" && cat "$tmp" > "$file"
    rm -f "$tmp" "$mimes_file"
}

mimeapps_remove_id() {
    local id="$1" f tmp
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        backup_file "$f"
        tmp=$(mktemp)
        awk -v id="$id" '
            function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
            /^\[/ { sec = $0; gsub(/\r/, "", sec); print; next }
            sec == "[Default Applications]" || sec == "[Added Associations]" || sec == "[Removed Associations]" {
                if ($0 ~ /^[^#;=\r][^=\r]*=/) {
                    eq = index($0, "=")
                    key = substr($0, 1, eq - 1)
                    val = substr($0, eq + 1)
                    out = ""; rest = val; any = 0
                    while ((p = index(rest, ";")) > 0) {
                        tok = substr(rest, 1, p - 1); rest = substr(rest, p + 1)
                        if (trim(tok) != id) { out = out tok ";"; any = 1 }
                    }
                    if (rest != "") {
                        if (trim(rest) != id) { out = out rest; any = 1 }
                    }
                    if (any) print key "=" out
                    next
                }
            }
            { print }
        ' "$f" > "$tmp" && cat "$tmp" > "$f"
        rm -f "$tmp"
    done < <(mimeapps_paths)
}

refresh_caches() {
    local cmd
    command_exists update-desktop-database && update-desktop-database "$APPS_DIR" 2>/dev/null
    for cmd in $(compgen -c | grep -E '^(gtk[0-9]*-)?update-icon-cache$' | sort -u); do
        command_exists "$cmd" && "$cmd" -f -t "$ICONS_DIR" >/dev/null 2>&1
    done
    for cmd in $(compgen -c | grep -E '^kbuildsycoca[0-9]*$' | sort -u); do
        command_exists "$cmd" && "$cmd" --noincremental >/dev/null 2>&1
    done
}

# ---------------------------------------------------------------------------
# Generated uninstaller
# ---------------------------------------------------------------------------

write_uninstaller() {
    local slug="$1" name="$2" data_dir="$3" data_guard="$4" class="$5"
    local icon="$6" desktop="$7" manifest="$8"
    shift 8
    local -a mimes=("$@")
    local dir="$SUPPORT_DIR/$slug" uninstaller="$SUPPORT_DIR/$slug/uninstall.sh"
    local tmp mimes_q='' m q

    for m in "${mimes[@]:-}"; do mimes_q+=" $(shell_quote "$m")"; done
    mkdir -p "$dir"

    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
# Generated by __BPM_MARKER__ on __BPM_GENERATED__.
# Profile: __BPM_NAME__
# Slug:    __BPM_SLUG__
# Data:    __BPM_DATA_DIR__
# Frozen at creation time; later manager versions never rewrite this file.

set -uo pipefail

SLUG=__BPM_SLUG__
NAME=__BPM_NAME__
DATA_DIR=__BPM_DATA_DIR__
DATA_GUARD=__BPM_DATA_GUARD__
CLASS=__BPM_CLASS__
ICON=__BPM_ICON__
DESKTOP=__BPM_DESKTOP__
MANIFEST=__BPM_MANIFEST__
SUPPORT_DIR=__BPM_SUPPORT_DIR__
MIMES=( __BPM_MIMES__ )
KEEP_DATA=0

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
LEGACY_UNINSTALL_DESKTOP="${XDG_DATA_HOME}/applications/${CLASS}-uninstall.desktop"

info() { echo -e "\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m!!\033[0m $*" >&2; }
ok()   { echo -e "\033[1;32m✓\033[0m $*"; }

mimeapps_paths() {
    local c p out=() parts=()
    out+=("$XDG_CONFIG_HOME/mimeapps.list"
          "$XDG_DATA_HOME/applications/mimeapps.list"
          "$XDG_DATA_HOME/applications/defaults.list")
    IFS=: read -ra parts <<< "${XDG_CURRENT_DESKTOP:-}"
    for p in "${parts[@]:-}"; do
        c=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]'); c=${c#x-}
        [[ -n "$c" ]] && out+=("$XDG_CONFIG_HOME/$c-mimeapps.list"
                               "$XDG_DATA_HOME/applications/$c-mimeapps.list")
    done
    for p in "${out[@]}"; do printf '%s\n' "$p"; done | awk '!seen[$0]++'
}

mimeapps_remove_id() {
    local id="$1" f tmp
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        tmp=$(mktemp)
        awk -v id="$id" '
            function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
            /^\[/ { sec = $0; gsub(/\r/, "", sec); print; next }
            sec == "[Default Applications]" || sec == "[Added Associations]" || sec == "[Removed Associations]" {
                if ($0 ~ /^[^#;=\r][^=\r]*=/) {
                    eq = index($0, "=")
                    key = substr($0, 1, eq - 1)
                    val = substr($0, eq + 1)
                    out = ""; rest = val; any = 0
                    while ((p = index(rest, ";")) > 0) {
                        tok = substr(rest, 1, p - 1); rest = substr(rest, p + 1)
                        if (trim(tok) != id) { out = out tok ";"; any = 1 }
                    }
                    if (rest != "") {
                        if (trim(rest) != id) { out = out rest; any = 1 }
                    }
                    if (any) print key "=" out
                    next
                }
            }
            { print }
        ' "$f" > "$tmp" && cat "$tmp" > "$f"
        rm -f "$tmp"
    done < <(mimeapps_paths)
}

refresh() {
    local cmd
    command_exists() { command -v "$1" >/dev/null 2>&1; }
    for cmd in $(compgen -c | grep -E '^(gtk[0-9]*-)?update-icon-cache$' | sort -u); do
        command_exists "$cmd" && "$cmd" -f -t "${XDG_DATA_HOME}/icons" >/dev/null 2>&1
    done
    for cmd in $(compgen -c | grep -E '^kbuildsycoca[0-9]*$' | sort -u); do
        command_exists "$cmd" && "$cmd" --noincremental >/dev/null 2>&1
    done
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "${XDG_DATA_HOME}/applications" 2>/dev/null
    return 0
}

for arg in "$@"; do
    case "$arg" in
        --keep-data) KEEP_DATA=1 ;;
    esac
done

ID="${CLASS}.desktop"

for f in "$DESKTOP" "$LEGACY_UNINSTALL_DESKTOP" "$MANIFEST"; do
    if [[ -n "$f" && -e "$f" ]]; then
        rm -f -- "$f" && ok "  removed $f"
    fi
done
if [[ -n "$ICON" && -f "$ICON" ]]; then
    rm -f -- "$ICON" && ok "  removed icon $ICON"
fi

mimeapps_remove_id "$ID"
ok "  cleared file/protocol choices for $ID"

if [[ -n "$DATA_DIR" && -d "$DATA_DIR" ]]; then
    if [[ $DATA_DIR == $DATA_GUARD ]]; then
        if (( KEEP_DATA )); then
            echo "  Kept $DATA_DIR (requested)"
        else
            echo
            warn "Profile data for '$NAME' still exists at: $DATA_DIR"
            if read -r -p "  Delete this browsing data too? This is permanent. Type 'yes' to delete, anything else to keep: " CONFIRM; then
                if [[ "$CONFIRM" == "yes" ]]; then
                    rm -rf -- "$DATA_DIR" && ok "  deleted $DATA_DIR"
                else
                    echo "  Kept $DATA_DIR"
                fi
            else
                echo "  Kept $DATA_DIR (no interactive input)"
            fi
        fi
    else
        warn "  Refusing to touch data outside the generated profile root: $DATA_DIR"
    fi
fi

refresh
ok "Removed profile: $NAME"

self_dir="$SUPPORT_DIR/$SLUG"
[[ -d "$self_dir" ]] && rm -rf -- "$self_dir"
if [[ -d "$SUPPORT_DIR" ]] && [[ -z "$(ls -A "$SUPPORT_DIR" 2>/dev/null)" ]]; then
    rmdir -- "$SUPPORT_DIR" 2>/dev/null || true
fi
EOF

    q_slug=$(shell_quote "$slug")
    q_name=$(shell_quote "$name")
    q_data=$(shell_quote "$data_dir")
    q_guard=$(shell_quote "$data_guard")
    q_class=$(shell_quote "$class")
    q_icon=$(shell_quote "$icon")
    q_desktop=$(shell_quote "$desktop")
    q_manifest=$(shell_quote "$manifest")
    q_support=$(shell_quote "$SUPPORT_DIR")
    q_marker=$(shell_quote "$MARKER")
    q_generated=$(shell_quote "$(date -Is)")

    sed -e "s|__BPM_SLUG__|$(sed_repl "$q_slug")|g" \
        -e "s|__BPM_NAME__|$(sed_repl "$q_name")|g" \
        -e "s|__BPM_DATA_DIR__|$(sed_repl "$q_data")|g" \
        -e "s|__BPM_DATA_GUARD__|$(sed_repl "$q_guard")|g" \
        -e "s|__BPM_CLASS__|$(sed_repl "$q_class")|g" \
        -e "s|__BPM_ICON__|$(sed_repl "$q_icon")|g" \
        -e "s|__BPM_DESKTOP__|$(sed_repl "$q_desktop")|g" \
        -e "s|__BPM_MANIFEST__|$(sed_repl "$q_manifest")|g" \
        -e "s|__BPM_SUPPORT_DIR__|$(sed_repl "$q_support")|g" \
        -e "s|__BPM_MARKER__|$(sed_repl "$q_marker")|g" \
        -e "s|__BPM_GENERATED__|$(sed_repl "$q_generated")|g" \
        -e "s|__BPM_MIMES__|$(sed_repl "${mimes_q# }")|g" \
        "$tmp" > "$uninstaller"
    rm -f "$tmp"
    chmod +x "$uninstaller"

    cat > "$manifest" <<EOF
format=$FORMAT_VERSION
slug=$slug
name=$name
class=$class
data_dir=$data_dir
data_guard=$data_guard
icon=$icon
desktop=$desktop
generated=$(date -Is)
mimes=$(printf '%s;' "${mimes[@]:-}")
EOF
}

# ---------------------------------------------------------------------------
# Desktop entry creation
# ---------------------------------------------------------------------------

write_profile_desktop() {
    local path="$1" name="$2" slug="$3" base_bin="$4" data_dir="$5" class="$6"
    local icon="$7" tryexec="$8" uninstaller="$9" comment="${10}"
    shift 10
    local -a mimes=("$@")
    local mime_line='' m

    for m in "${mimes[@]:-}"; do mime_line+="$m;"; done

    cat > "$path" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$(desk_escape "$name")
Comment=$(desk_escape "$comment")
Exec=$(desk_escape "$base_bin") --user-data-dir="$(desk_escape "$data_dir" | sed -e 's/"/\\"/g')" --class=$class %U
Icon=$(desk_escape "$icon")
Categories=Network;WebBrowser;
MimeType=$mime_line
StartupWMClass=$class
StartupNotify=true
TryExec=$(desk_escape "$tryexec")
Actions=UninstallProfile;
X-BPM-Marker=$(desk_escape "$MARKER")
X-BPM-Role=$PROFILE_ROLE
X-BPM-Slug=$slug
X-BPM-DataDir=$(desk_escape "$data_dir")
X-BPM-Version=$FORMAT_VERSION

[Desktop Action UninstallProfile]
Name=Uninstall $(desk_escape "$name")
Icon=$(desk_escape "$icon")
Exec=$(desk_escape "$uninstaller")
EOF
    chmod +x "$path"
}

# ---------------------------------------------------------------------------
# Variant/icon discovery
# ---------------------------------------------------------------------------

root_for_binary() {
    local bin="$1" base suffix root
    if [[ "$bin" == *origin* ]]; then base='Brave-Origin'; else base='Brave-Browser'; fi
    case "$bin" in
        *nightly*) suffix='Nightly' ;;
        *beta*)    suffix='Beta' ;;
        *)         suffix='' ;;
    esac
    root="$XDG_CONFIG_HOME/BraveSoftware/$base"
    [[ -n "$suffix" ]] && root="$root-$suffix"
    printf '%s' "$root"
}

declare -a V_KEYS=()
declare -A V_BIN=() V_ROOT=() V_LABEL=() V_ICONHINT=() V_DESKTOP=()

add_variant() {
    local key="$1" bin="$2" root="$3" label="$4" iconhint="$5" desktop
    [[ -n "${V_BIN[$key]:-}" ]] && return 0
    [[ -n "${V_BIN_BY_BIN[$bin]:-}" ]] && return 0
    desktop=$(desktop_for_command "$bin")
    [[ -z "$desktop" ]] && desktop=$(brave_desktop_files | head -n1)
    if [[ -n "$desktop" && -n "$(desk_field "$desktop" Icon)" ]]; then
        iconhint=$(desk_field "$desktop" Icon)
    fi
    iconhint=${iconhint%% *}; iconhint=${iconhint##*/}; iconhint=${iconhint%.*}
    [[ -z "$iconhint" ]] && iconhint='brave'
    V_KEYS+=("$key")
    V_BIN["$key"]="$bin"; V_ROOT["$key"]="$root"
    V_LABEL["$key"]="$label"; V_ICONHINT["$key"]="$iconhint"
    V_DESKTOP["$key"]="$desktop"
    V_BIN_BY_BIN["$bin"]="$key"
}

declare -A V_BIN_BY_BIN=()

discover_variants() {
    local key bin p f label icon desktop

    info "Detecting installed Brave variants..."

    for key in stable-browser stable-brave beta nightly origin-stable origin-beta origin-nightly; do
        case "$key" in
            stable-browser) bin='brave-browser'; icon='brave-desktop' ;;
            stable-brave)   bin='brave';        icon='brave-desktop' ;;
            beta)           bin='brave-browser-beta'; icon='brave-desktop' ;;
            nightly)        bin='brave-browser-nightly'; icon='brave-desktop' ;;
            origin-stable)  bin='brave-origin'; icon='brave-origin' ;;
            origin-beta)    bin='brave-origin-beta'; icon='brave-origin-beta' ;;
            origin-nightly) bin='brave-origin-nightly'; icon='brave-origin-nightly' ;;
        esac
        command_exists "$bin" && add_variant "$key" "$bin" "$(root_for_binary "$bin")" \
            "Brave ($key)" "$icon"
    done

    # Anything else called brave* on PATH is picked up too.
    IFS=: read -ra _path_dirs <<< "$PATH"
    for p in "${_path_dirs[@]:-}"; do
        [[ -d "$p" ]] || continue
        for f in "$p"/brave*; do
            [[ -x "$f" ]] || continue
            bin=$(basename "$f")
            command_exists "$bin" || continue
            desktop=$(desktop_for_command "$bin")
            label=$(desk_field "$desktop" Name)
            [[ -z "$label" ]] && label="$bin"
            add_variant "path-$bin" "$bin" "$(root_for_binary "$bin")" "$label" \
                "$(desk_field "$desktop" Icon)"
        done
    done

    if command_exists snap && snap list 2>/dev/null | grep -qi '^brave '; then
        desktop=$(desktop_for_command 'brave')
        add_variant 'snap' 'brave' "$XDG_DATA_HOME/snap/brave/current/.config/BraveSoftware/Brave-Browser" \
            "Brave (snap)" "$(desk_field "$desktop" Icon)"
    fi
    if command_exists flatpak && flatpak list --app --columns=application 2>/dev/null | grep -qi '^com\.brave\.Browser$'; then
        desktop=$(desktop_for_command 'flatpak run com.brave.Browser')
        add_variant 'flatpak' 'flatpak run com.brave.Browser' \
            "$HOME/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser" \
            "Brave (flatpak)" "$(desk_field "$desktop" Icon)"
    fi

    [[ ${#V_KEYS[@]} -eq 0 ]] && die "No Brave installation found. Install Brave first (or place a Brave .desktop registration in an XDG applications directory)."
}

rasterize_svg() {
    local src="$1" dst="$2"
    if command_exists rsvg-convert; then
        rsvg-convert -w 256 -h 256 "$src" -o "$dst"
    elif command_exists inkscape; then
        inkscape "$src" --export-type=png --export-filename="$dst" -w 256 -h 256 >/dev/null 2>&1
    else
        im -density 256 -background none "$src" -resize 256x256 "$dst"
    fi
}

find_base_icon() {
    local key="$1" hint="${V_ICONHINT[$1]}" f dims w h area best_png='' best_area=0 best_svg=''
    local -a roots=() candidates=()

    while IFS= read -r f; do roots+=("$f"); done < <(icon_roots)

    echo -e "\033[1;34m==>\033[0m Looking for the icon of: ${V_LABEL[$key]} (hint: $hint)..." >&2
    for f in "${roots[@]:-}"; do
        while IFS= read -r c; do candidates+=("$c"); done < <(
            find "$f" -maxdepth 6 \
                \( -iname "${hint}.png" -o -iname "${hint}.svg" -o -iname "${hint}@*.png" \) \
                2>/dev/null | sort
        )
    done
    if [[ ${#candidates[@]} -eq 0 ]]; then
        for f in "${roots[@]:-}"; do
            while IFS= read -r c; do candidates+=("$c"); done < <(
                find "$f" -maxdepth 6 \( -iname '*brave*.png' -o -iname '*brave*.svg' \) 2>/dev/null | sort
            )
        done
    fi

    for f in "${candidates[@]:-}"; do
        [[ -f "$f" ]] || continue
        if [[ "$f" == *.svg ]]; then
            [[ -z "$best_svg" ]] && best_svg="$f"
            continue
        fi
        dims=$(identify -format "%w %h" "$f" 2>/dev/null | head -n1)
        [[ -z "$dims" ]] && continue
        w=${dims% *}; h=${dims#* }
        area=$(( w * h ))
        if (( area > best_area )); then best_area=$area; best_png="$f"; fi
    done

    if [[ -n "$best_png" ]]; then
        printf '%s' "$best_png"
    elif [[ -n "$best_svg" ]]; then
        echo -e "\033[1;34m==>\033[0m Only found an SVG icon ($best_svg), rasterizing to 256x256..." >&2
        rasterize_svg "$best_svg" "$WORKDIR/base.png" || die "Failed to rasterize $best_svg."
        printf '%s' "$WORKDIR/base.png"
    else
        die "Could not find an icon for ${V_LABEL[$key]} in any XDG icon directory."
    fi
}

mimes_for_variant() {
    local key="$1" f="${V_DESKTOP[$1]:-}" out=()
    [[ -z "$f" || ! -f "$f" ]] && f=$(desktop_for_command "${V_BIN[$key]}")
    [[ -n "$f" ]] && mapfile -t out < <(mimes_from_desktop "$f")
    if [[ ${#out[@]} -eq 0 ]]; then
        mapfile -t out < <(all_brave_mimes)
    fi
    [[ ${#out[@]} -eq 0 ]] && warn "No MIME types found in any Brave desktop registration for ${V_LABEL[$key]}; the profile will only have a launcher."
    printf '%s\n' "${out[@]:-}"
}

# ---------------------------------------------------------------------------
# Profile discovery
# ---------------------------------------------------------------------------

profile_desktop_files() {
    local f role wm
    while IFS= read -r f; do
        # Only user-installed launchers are ours. System Brave entries can
        # also have a brave-* StartupWMClass and must never be modified.
        [[ "$f" == "$APPS_DIR"/* || "$(desk_field "$f" X-BPM-Marker)" == "$MARKER" ]] || continue
        role=$(desk_field "$f" X-BPM-Role)
        wm=$(desk_field "$f" StartupWMClass)
        if [[ "$role" == "$PROFILE_ROLE" || ( -z "$role" && "$wm" == brave-* ) ]]; then
            printf '%s\n' "$f"
        fi
    done < <(desktop_files)
}

profile_from_desktop() {
    local f="$1" exec_line datadir class slug
    P_PATH="$f"
    P_NAME=$(desk_field "$f" Name)
    P_ICON=$(desk_field "$f" Icon)
    P_CLASS=$(desk_field "$f" StartupWMClass)
    P_BASE_BIN=$(desk_field "$f" Exec)
    P_BASE_BIN=${P_BASE_BIN%% --user-data-dir=*}
    [[ -z "$P_NAME" ]] && P_NAME='<unnamed>'
    P_DATADIR=$(desk_field "$f" X-BPM-DataDir)
    if [[ -z "$P_DATADIR" ]]; then
        exec_line=$(desk_field "$f" Exec)
        P_DATADIR=$(printf '%s' "$exec_line" | grep -oE -- '--user-data-dir=("[^"]*"|[^ ]*)' | sed -E 's/--user-data-dir=//; s/^"//; s/"$//' | head -n1)
    fi
    class="$P_CLASS"; slug=$(desk_field "$f" X-BPM-Slug)
    [[ -z "$slug" ]] && slug=${class#brave-}
    [[ -z "$slug" ]] && slug=$(slugify "$P_NAME")
    P_SLUG="$slug"
    P_UNINSTALLER="$SUPPORT_DIR/$slug/uninstall.sh"
    P_UNINSTALL_DESKTOP="$APPS_DIR/${class}-uninstall.desktop"
    P_VERSION=$(desk_field "$f" X-BPM-Version)
}

slug_in_use() {
    local slug="$1" f role
    while IFS= read -r f; do
        role=$(desk_field "$f" X-BPM-Role)
        [[ "$role" == "$UNINSTALL_ROLE" ]] && continue
        [[ $(desk_field "$f" X-BPM-Slug) == "$slug" ]] && return 0
    done < <(desktop_files)
    return 1
}

# ---------------------------------------------------------------------------
# ADD
# ---------------------------------------------------------------------------

do_add() {
    if command_exists magick; then IM_CONVERT='magick'
    elif command_exists convert; then IM_CONVERT='convert'
    else die "ImageMagick is required to draw the colored dot on the icon. Please install it and try again."
    fi
    command_exists identify || die "ImageMagick's 'identify' not found (should ship alongside convert/magick)."
    im() { "$IM_CONVERT" "$@"; }

    discover_variants

    echo
    info "Found the following Brave installation(s):"
    for i in "${!V_KEYS[@]}"; do
        k="${V_KEYS[$i]}"
        printf "  %2d) %s  [%s]\n" "$((i+1))" "${V_LABEL[$k]}" "${V_BIN[$k]}"
    done
    echo

    if [[ ${#V_KEYS[@]} -eq 1 ]]; then
        CHOICE=1
        ok "Only one variant found, using it: ${V_LABEL[${V_KEYS[0]}]}"
    else
        while true; do
            CHOICE=$(ask "Which Brave variant should the profiles use? (number)" "1")
            [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#V_KEYS[@]} )) && break
            warn "Enter a number between 1 and ${#V_KEYS[@]}."
        done
    fi

    SEL_KEY="${V_KEYS[$((CHOICE-1))]}"
    BASE_BIN="${V_BIN[$SEL_KEY]}"
    BASE_ROOT="${V_ROOT[$SEL_KEY]}"
    TRYEXEC_BIN="${BASE_BIN%% *}"
    TRYEXEC_BIN=${TRYEXEC_BIN//\"/}
    SEL_DESKTOP="${V_DESKTOP[$SEL_KEY]:-}"
    SEL_LABEL="${V_LABEL[$SEL_KEY]}"

    ok "Using: $SEL_LABEL"

    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT
    BASE_ICON=$(find_base_icon "$SEL_KEY")

    mapfile -t SEL_MIMES < <(mimes_for_variant "$SEL_KEY")
    if [[ ${#SEL_MIMES[@]} -gt 0 ]]; then
        ok "Registering ${#SEL_MIMES[@]} MIME type(s) read from ${SEL_DESKTOP:-the installed Brave desktop registration}"
    fi

    while true; do
        NUM_PROFILES=$(ask "How many profiles do you want to create?" "")
        [[ "$NUM_PROFILES" =~ ^[0-9]+$ ]] && (( NUM_PROFILES > 0 )) && break
        warn "Enter a positive whole number."
    done

    declare -a P_NAME=() P_SLUG=() P_COLOR=()

    echo
    info "Enter details for each profile. Color can be any ImageMagick color name (e.g. red, dodgerblue, orange) or a hex code (e.g. #ff5500)."
    for (( i=1; i<=NUM_PROFILES; i++ )); do
        echo
        info "Profile $i of $NUM_PROFILES"
        NAME=$(ask_required "  Name (exactly as you want it to appear)")
        SLUG=$(slugify "$NAME")
        [[ -z "$SLUG" ]] && SLUG="profile-$i"

        BASE_SLUG="$SLUG"; DUP=2
        while slug_in_use "$SLUG"; do
            SLUG="${BASE_SLUG}-${DUP}"
            ((DUP++))
        done
        [[ "$SLUG" != "$BASE_SLUG" ]] && warn "  '$NAME' slug is already in use, using '$SLUG' instead."

        while true; do
            COLOR=$(ask "  Dot color for '$NAME'" "red")
            if im -size 4x4 xc:none -fill "$COLOR" -draw "point 1,1" "$WORKDIR/colortest.png" 2>/dev/null; then
                break
            fi
            warn "ImageMagick didn't recognize color '$COLOR', try again (e.g. 'blue', '#00aa00')."
        done

        P_NAME+=("$NAME"); P_SLUG+=("$SLUG"); P_COLOR+=("$COLOR")
    done

    mkdir -p "$APPS_DIR" "$ICONS_DIR" "$SUPPORT_DIR"
    BASE_W=$(identify -format "%w" "$BASE_ICON")

    echo
    info "Creating profiles..."

    for i in "${!P_NAME[@]}"; do
        NAME="${P_NAME[$i]}"; SLUG="${P_SLUG[$i]}"; COLOR="${P_COLOR[$i]}"
        CLASS="${CLASS_PREFIX}-${SLUG}"
        USER_DATA_DIR="${BASE_ROOT}-${SLUG}"
        ICON_PATH="${ICONS_DIR}/${CLASS}.png"
        DESKTOP_PATH="${APPS_DIR}/${CLASS}.desktop"
        LEGACY_UNINSTALL_DESKTOP_PATH="${APPS_DIR}/${CLASS}-uninstall.desktop"
        UNINSTALLER_PATH="$SUPPORT_DIR/$SLUG/uninstall.sh"
        MANIFEST_PATH="$SUPPORT_DIR/$SLUG/manifest"
        rm -f -- "$LEGACY_UNINSTALL_DESKTOP_PATH"

        echo
        info "[$NAME] -> class=$CLASS  data-dir=$USER_DATA_DIR"

        mkdir -p "$USER_DATA_DIR"

        DOT_D=$(( BASE_W * 38 / 100 )); (( DOT_D < 12 )) && DOT_D=12
        INSET=$(( BASE_W * 4 / 100 ))
        RING=$(( DOT_D / 12 )); (( RING < 1 )) && RING=1
        CENTER=$(( DOT_D / 2 ))
        EDGE=$RING

        DOT_PNG="$WORKDIR/dot-${SLUG}.png"
        im -size "${DOT_D}x${DOT_D}" xc:none \
            -fill "$COLOR" -stroke "#00000099" -strokewidth "$RING" \
            -draw "circle ${CENTER},${CENTER} ${CENTER},${EDGE}" \
            "$DOT_PNG" || die "Failed drawing dot for profile '$NAME'"
        im "$BASE_ICON" "$DOT_PNG" -gravity northeast -geometry "+${INSET}+${INSET}" -composite \
            "$ICON_PATH" || die "Failed compositing icon for profile '$NAME'"
        ok "  icon -> $ICON_PATH"

        DATA_GUARD="${BASE_ROOT}-"*
        write_uninstaller "$SLUG" "$NAME" "$USER_DATA_DIR" "$DATA_GUARD" "$CLASS" \
            "$ICON_PATH" "$DESKTOP_PATH" "$MANIFEST_PATH" "${SEL_MIMES[@]:-}"

        write_profile_desktop "$DESKTOP_PATH" "$NAME" "$SLUG" "$BASE_BIN" "$USER_DATA_DIR" "$CLASS" \
            "$ICON_PATH" "$TRYEXEC_BIN" "$UNINSTALLER_PATH" "Brave browser - $NAME profile" \
            "${SEL_MIMES[@]:-}"
        ok "  launcher -> $DESKTOP_PATH"

        if [[ ${#SEL_MIMES[@]} -gt 0 ]]; then
            mimeapps_add_associations "$XDG_CONFIG_HOME/mimeapps.list" "${CLASS}.desktop" "${SEL_MIMES[@]}"
            ok "  registered MIME associations"
        fi

        if command_exists desktop-file-validate; then
            desktop-file-validate "$DESKTOP_PATH" || warn "  desktop-file-validate reported issues in $DESKTOP_PATH"
        fi
    done

    refresh_caches

    echo
    ok "Done! Created ${#P_NAME[@]} profile(s):"
    for i in "${!P_NAME[@]}"; do
        echo "   - ${P_NAME[$i]}  (class: brave-${P_SLUG[$i]})"
    done
    echo
    echo "Each profile is now a separate browser app. Pick one yourself in your"
    echo "desktop's Default Applications / Open With settings; this script never"
    echo "changes your chosen default."
}

# ---------------------------------------------------------------------------
# REMOVE
# ---------------------------------------------------------------------------

remove_profile_inline() {
    local f="$1" id name datadir icon slug class
    profile_from_desktop "$f"
    id="${P_CLASS}.desktop"; name="$P_NAME"; datadir="$P_DATADIR"; icon="$P_ICON"; slug="$P_SLUG"; class="$P_CLASS"

    info "Removing launcher for '$name'"
    backup_file "$P_PATH"
    rm -f -- "$P_PATH" && ok "  removed $P_PATH"
    rm -f -- "$P_UNINSTALL_DESKTOP" && ok "  removed $P_UNINSTALL_DESKTOP"
    if [[ -n "$icon" && "$icon" == "$ICONS_DIR"/* && -f "$icon" ]]; then
        rm -f -- "$icon" && ok "  removed icon $icon"
    fi
    mimeapps_remove_id "$id"
    ok "  cleared file/protocol choices for $id"
    [[ -d "$SUPPORT_DIR/$slug" ]] && rm -rf -- "$SUPPORT_DIR/$slug"

    if [[ -n "$datadir" && "$datadir" != '<unknown>' && -d "$datadir" ]]; then
        local guard="${datadir%-*}-"*
        if [[ $datadir == $guard ]]; then
            echo
            warn "Profile data for '$name' still exists at: $datadir"
            read -r -p "  Delete this browsing data too? This is permanent. Type 'yes' to delete, anything else to keep: " CONFIRM
            if [[ "$CONFIRM" == "yes" ]]; then
                rm -rf -- "$datadir" && ok "  deleted $datadir"
            else
                echo "  Kept $datadir"
            fi
        else
            warn "  Refusing to touch data outside the generated profile root: $datadir"
        fi
    fi
}

do_remove() {
    [[ -d "$APPS_DIR" ]] || { echo "No launcher directory found at $APPS_DIR"; return; }

    mapfile -t CANDIDATES < <(profile_desktop_files)
    if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
        echo "No Brave profile launchers found under $APPS_DIR."
        return
    fi

    declare -a D_PATH=() D_NAME=() D_DATADIR=()
    for f in "${CANDIDATES[@]:-}"; do
        profile_from_desktop "$f"
        D_PATH+=("$f"); D_NAME+=("$P_NAME"); D_DATADIR+=("${P_DATADIR:-<unknown>}")
    done

    echo
    info "Found ${#D_PATH[@]} Brave profile launcher(s):"
    for i in "${!D_PATH[@]}"; do
        printf "  %2d) %-25s data: %s\n" "$((i+1))" "${D_NAME[$i]}" "${D_DATADIR[$i]}"
        printf "      desktop file: %s\n" "${D_PATH[$i]}"
    done
    echo

    read -r -p "Which ones to remove? (comma-separated numbers, 'all', or 'q' to quit): " SEL
    [[ "$SEL" == "q" || -z "$SEL" ]] && { echo "Nothing removed."; return; }

    declare -a INDICES=()
    if [[ "$SEL" == "all" ]]; then
        for i in "${!D_PATH[@]}"; do INDICES+=("$i"); done
    else
        IFS=',' read -ra RAW <<< "$SEL"
        for n in "${RAW[@]:-}"; do
            n=$(echo "$n" | tr -d '[:space:]')
            [[ "$n" =~ ^[0-9]+$ ]] || continue
            idx=$((n-1))
            (( idx >= 0 && idx < ${#D_PATH[@]} )) && INDICES+=("$idx")
        done
    fi

    [[ ${#INDICES[@]} -eq 0 ]] && { echo "Nothing selected, nothing removed."; return; }

    echo
    for idx in "${INDICES[@]}"; do
        f="${D_PATH[$idx]}"
        profile_from_desktop "$f"
        if [[ -x "$P_UNINSTALLER" ]]; then
            info "Removing '$P_NAME' with its saved uninstaller..."
            bash "$P_UNINSTALLER"
        else
            remove_profile_inline "$f"
        fi
        echo
    done

    refresh_caches
    ok "Done."
}

# ---------------------------------------------------------------------------
# Upgrade older launchers in place
# ---------------------------------------------------------------------------

upgrade_legacy_profiles() {
    local f upgraded=0 slug class name icon datadir base_bin guard desktop needs
    local -a mimes=()

    while IFS= read -r f; do
        profile_from_desktop "$f"
        slug="$P_SLUG"; class="$P_CLASS"; name="$P_NAME"; icon="$P_ICON"; datadir="$P_DATADIR"
        base_bin="$P_BASE_BIN"
        [[ -z "$datadir" || "$datadir" == '<unknown>' ]] && { warn "Skipping $f: no data directory found."; continue; }
        [[ -z "$base_bin" ]] && { warn "Skipping $f: no Exec command found."; continue; }

        needs=0
        [[ -e "$P_UNINSTALL_DESKTOP" ]] && needs=1
        if [[ "${P_VERSION:-}" == "$FORMAT_VERSION" && -x "$P_UNINSTALLER" &&
             -n "$(desk_field "$f" MimeType)" ]] && (( needs == 0 )); then
            continue
        fi

        info "Upgrading '$name' to format $FORMAT_VERSION..."
        backup_file "$f"
        if [[ -e "$P_UNINSTALL_DESKTOP" ]]; then
            backup_file "$P_UNINSTALL_DESKTOP"
            rm -f -- "$P_UNINSTALL_DESKTOP" && ok "  removed uninstall launcher $P_UNINSTALL_DESKTOP"
        fi

        mapfile -t mimes < <(mimes_from_desktop "$(desktop_for_command "$base_bin")")
        if [[ ${#mimes[@]} -eq 0 ]]; then
            mapfile -t mimes < <(all_brave_mimes)
        fi

        guard="$datadir"
        desktop="$f"
        write_uninstaller "$slug" "$name" "$datadir" "$guard" "$class" "$icon" \
            "$desktop" "$SUPPORT_DIR/$slug/manifest" "${mimes[@]:-}"
        write_profile_desktop "$desktop" "$name" "$slug" "$base_bin" "$datadir" "$class" "$icon" \
            "${base_bin%% *}" "$P_UNINSTALLER" "Brave browser - $name profile" "${mimes[@]:-}"
        if [[ ${#mimes[@]} -gt 0 ]]; then
            mimeapps_add_associations "$XDG_CONFIG_HOME/mimeapps.list" "$class.desktop" "${mimes[@]}"
        fi
        if command_exists desktop-file-validate; then
            desktop-file-validate "$desktop" || warn "  desktop-file-validate reported issues in $desktop"
        fi
        ok "  upgraded $desktop"
        upgraded=$((upgraded+1))
    done < <(profile_desktop_files)

    if (( upgraded > 0 )); then
        refresh_caches
        ok "Upgraded $upgraded existing profile(s)."
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

echo "Brave profile manager"
echo "======================"
upgrade_legacy_profiles
while true; do
    echo
    echo "  [1] Add / create new profile(s)"
    echo "  [2] Remove existing profile(s)"
    echo "  [Q] Quit"
    echo
    MODE=$(ask "Choose 1, 2 or Q" "1")
    case "$MODE" in
        1) do_add; read -r -p "Press Enter to continue" _ ;;
        2) do_remove; read -r -p "Press Enter to continue" _ ;;
        [Qq]) echo "Bye."; break ;;
        *) warn "Enter 1, 2 or Q." ;;
    esac
done
