#!/usr/bin/env bash
#
# brave-profile-manager.sh
#
# Add or remove fully independent Brave browser profiles as .desktop
# launchers, based on the approach described here:
# https://gist.github.com/pannal/d398ee9801a8c6d0e44b1027af193610
#
# ADD:
#   - detects installed Brave variants (stable, Beta, Nightly, Origin +
#     its Beta/Nightly, snap, flatpak) and lets you pick one
#   - creates a separate --user-data-dir per profile (so KDE/GNOME treat
#     each as its own app instead of grouping windows together)
#   - extracts the icon from the SELECTED variant itself and draws a
#     colored dot (your choice of color) in the top-right corner
#   - writes a .desktop launcher named exactly what you typed
#
# REMOVE:
#   - lists launchers previously created by this script
#   - always removes the .desktop file + generated icon
#   - only deletes the profile's browsing data if you explicitly type
#     "yes" when asked, per profile
#
# Requires: bash, coreutils, ImageMagick (convert/magick + identify) for
# the ADD path. REMOVE has no extra dependencies.

set -uo pipefail

APPS_DIR="$HOME/.local/share/applications"
ICONS_DIR="$HOME/.local/share/icons"

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

refresh_caches() {
    command_exists update-desktop-database && update-desktop-database "$APPS_DIR" 2>/dev/null
    command_exists gtk-update-icon-cache && gtk-update-icon-cache -f -t "$ICONS_DIR" 2>/dev/null
    command_exists kbuildsycoca6 && kbuildsycoca6 --noincremental >/dev/null 2>&1
    command_exists kbuildsycoca5 && kbuildsycoca5 --noincremental >/dev/null 2>&1
}

# =============================================================================
# ADD
# =============================================================================

do_add() {
    IM_CONVERT=""
    if command_exists magick; then
        IM_CONVERT="magick"
    elif command_exists convert; then
        IM_CONVERT="convert"
    else
        die "ImageMagick is required to draw the colored dot on the icon. Please install it and try again."
    fi
    command_exists identify || die "ImageMagick's 'identify' not found (should ship alongside convert/magick)."
    im() { "$IM_CONVERT" "$@"; }

    # --- 1. Detect installed Brave variants ---------------------------------

    declare -a V_KEYS=()
    declare -A V_BIN=() V_ROOT=() V_LABEL=() V_ICONHINT=()

    add_variant() {
        local key="$1" bin="$2" root="$3" label="$4" iconhint="$5"
        V_KEYS+=("$key")
        V_BIN["$key"]="$bin"; V_ROOT["$key"]="$root"
        V_LABEL["$key"]="$label"; V_ICONHINT["$key"]="$iconhint"
    }

    info "Detecting installed Brave variants..."

    command_exists brave-browser && add_variant "stable-browser" "brave-browser" \
        "$HOME/.config/BraveSoftware/Brave-Browser" "Brave (stable, brave-browser)" "brave-desktop"
    command_exists brave && add_variant "stable-brave" "brave" \
        "$HOME/.config/BraveSoftware/Brave-Browser" "Brave (stable, brave)" "brave-desktop"
    command_exists brave-browser-beta && add_variant "beta" "brave-browser-beta" \
        "$HOME/.config/BraveSoftware/Brave-Browser-Beta" "Brave Beta" "brave-desktop"
    command_exists brave-browser-nightly && add_variant "nightly" "brave-browser-nightly" \
        "$HOME/.config/BraveSoftware/Brave-Browser-Nightly" "Brave Nightly" "brave-desktop"

    # Brave Origin - stripped-down variant (no Leo/Tor/Wallet/Rewards/VPN)
    # https://brave.com/origin/
    command_exists brave-origin && add_variant "origin-stable" "brave-origin" \
        "$HOME/.config/BraveSoftware/Brave-Origin" "Brave Origin" "brave-origin"
    command_exists brave-origin-beta && add_variant "origin-beta" "brave-origin-beta" \
        "$HOME/.config/BraveSoftware/Brave-Origin-Beta" "Brave Origin Beta" "brave-origin-beta"
    command_exists brave-origin-nightly && add_variant "origin-nightly" "brave-origin-nightly" \
        "$HOME/.config/BraveSoftware/Brave-Origin-Nightly" "Brave Origin Nightly" "brave-origin-nightly"

    if command_exists snap && snap list 2>/dev/null | grep -qi '^brave '; then
        add_variant "snap" "brave" "$HOME/snap/brave/current/.config/BraveSoftware/Brave-Browser" \
            "Brave (snap)" "brave-desktop"
    fi
    if command_exists flatpak && flatpak list --app --columns=application 2>/dev/null | grep -qi '^com\.brave\.Browser$'; then
        add_variant "flatpak" "flatpak run com.brave.Browser" \
            "$HOME/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser" "Brave (flatpak)" "com.brave.Browser"
    fi

    [[ ${#V_KEYS[@]} -eq 0 ]] && die "No Brave installation found (checked brave, brave-browser, brave-browser-beta, brave-browser-nightly, brave-origin, brave-origin-beta, brave-origin-nightly, snap, flatpak). Install Brave first."

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
    ICON_HINT="${V_ICONHINT[$SEL_KEY]}"
    TRYEXEC_BIN="$BASE_BIN"
    [[ "$BASE_BIN" == flatpak* ]] && TRYEXEC_BIN="flatpak"

    ok "Using: ${V_LABEL[$SEL_KEY]}"

    # --- 2. Locate the icon for the SELECTED variant ------------------------

    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT

    SEARCH_DIRS=(
        /usr/share
        /opt /usr/lib
        /var/lib/flatpak/exports/share/icons
        /var/lib/snapd/desktop/icons
        /snap
        "$HOME/.local/share/icons"
        "$HOME/.local/share/flatpak/exports/share/icons"
        "$HOME/snap"
    )

    find_icon_candidates() {
        local pattern="$1"
        find "${SEARCH_DIRS[@]}" -maxdepth 8 \
            \( -iname "*${pattern}*.png" -o -iname "*${pattern}*.svg" \) \
            2>/dev/null
    }

    info "Looking for the icon of: ${V_LABEL[$SEL_KEY]}  (hint: $ICON_HINT)..."

    mapfile -t CANDIDATES < <(find_icon_candidates "$ICON_HINT")
    if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
        warn "No icon matched '$ICON_HINT' specifically, falling back to a generic 'brave' search..."
        mapfile -t CANDIDATES < <(find_icon_candidates "brave")
    fi

    BEST_PNG=""; BEST_AREA=0; BEST_SVG=""
    for f in "${CANDIDATES[@]:-}"; do
        [[ -z "$f" || ! -f "$f" ]] && continue
        if [[ "$f" == *.svg ]]; then
            [[ -z "$BEST_SVG" ]] && BEST_SVG="$f"
            continue
        fi
        dims=$(identify -format "%w %h" "$f" 2>/dev/null | head -n1)
        [[ -z "$dims" ]] && continue
        w=${dims% *}; h=${dims#* }
        area=$(( w * h ))
        if (( area > BEST_AREA )); then BEST_AREA=$area; BEST_PNG="$f"; fi
    done

    BASE_ICON=""
    if [[ -n "$BEST_PNG" ]]; then
        BASE_ICON="$BEST_PNG"
        ok "Extracted icon: $BASE_ICON"
    elif [[ -n "$BEST_SVG" ]]; then
        info "Only found an SVG icon ($BEST_SVG), rasterizing to 256x256..."
        BASE_ICON="$WORKDIR/base.png"
        im -density 256 -background none "$BEST_SVG" -resize 256x256 "$BASE_ICON" \
            || die "Failed to rasterize $BEST_SVG. Install librsvg (e.g. 'librsvg2-bin' / 'librsvg') and retry."
    else
        die "Could not find an icon for ${V_LABEL[$SEL_KEY]} anywhere under ${SEARCH_DIRS[*]}."
    fi

    # --- 3. Ask how many profiles, then per-profile name + dot color --------

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
        while printf '%s\n' "${P_SLUG[@]:-}" | grep -qx "$SLUG"; do
            SLUG="${BASE_SLUG}-${DUP}"
            ((DUP++))
        done
        [[ "$SLUG" != "$BASE_SLUG" ]] && warn "  '$NAME' slugifies the same as an earlier profile, using '$SLUG' instead."

        while true; do
            COLOR=$(ask "  Dot color for '$NAME'" "red")
            if im -size 4x4 xc:none -fill "$COLOR" -draw "point 1,1" "$WORKDIR/colortest.png" 2>/dev/null; then
                break
            fi
            warn "ImageMagick didn't recognize color '$COLOR', try again (e.g. 'blue', '#00aa00')."
        done

        P_NAME+=("$NAME"); P_SLUG+=("$SLUG"); P_COLOR+=("$COLOR")
    done

    # --- 4. Build each profile: user-data-dir, icon, .desktop --------------

    mkdir -p "$APPS_DIR" "$ICONS_DIR"
    BASE_W=$(identify -format "%w" "$BASE_ICON")

    echo
    info "Creating profiles..."

    for i in "${!P_NAME[@]}"; do
        NAME="${P_NAME[$i]}"; SLUG="${P_SLUG[$i]}"; COLOR="${P_COLOR[$i]}"
        CLASS="brave-${SLUG}"
        USER_DATA_DIR="${BASE_ROOT}-${SLUG}"
        ICON_PATH="${ICONS_DIR}/${CLASS}.png"
        DESKTOP_PATH="${APPS_DIR}/${CLASS}.desktop"

        echo
        info "[$NAME] -> class=$CLASS  data-dir=$USER_DATA_DIR"

        mkdir -p "$USER_DATA_DIR"

        # dot diameter ~38% of icon width, inset ~4% from the edge, thin
        # dark ring so it reads clearly against any color
        DOT_D=$(( BASE_W * 38 / 100 )); (( DOT_D < 12 )) && DOT_D=12
        INSET=$(( BASE_W * 4 / 100 ))
        RING=$(( DOT_D / 12 )); (( RING < 1 )) && RING=1
        CENTER=$(( DOT_D / 2 ))
        EDGE=$RING   # radius = CENTER - EDGE, leaves room for the stroke

        DOT_PNG="$WORKDIR/dot-${SLUG}.png"
        im -size "${DOT_D}x${DOT_D}" xc:none \
            -fill "$COLOR" -stroke "#00000099" -strokewidth "$RING" \
            -draw "circle ${CENTER},${CENTER} ${CENTER},${EDGE}" \
            "$DOT_PNG" || die "Failed drawing dot for profile '$NAME'"

        im "$BASE_ICON" "$DOT_PNG" -gravity northeast -geometry "+${INSET}+${INSET}" -composite \
            "$ICON_PATH" || die "Failed compositing icon for profile '$NAME'"

        ok "  icon -> $ICON_PATH"

        EXEC_LINE="$BASE_BIN --user-data-dir=\"$USER_DATA_DIR\" --class=$CLASS %U"

        cat > "$DESKTOP_PATH" <<EOF
[Desktop Entry]
Version=1.0
Name=$NAME
Comment=Brave browser - $NAME profile
Exec=$EXEC_LINE
Icon=$ICON_PATH
Type=Application
Categories=Network;WebBrowser;
StartupWMClass=$CLASS
StartupNotify=true
TryExec=$TRYEXEC_BIN
EOF
        chmod +x "$DESKTOP_PATH"
        ok "  launcher -> $DESKTOP_PATH"

        if command_exists desktop-file-validate; then
            desktop-file-validate "$DESKTOP_PATH" || warn "  desktop-file-validate reported issues in $DESKTOP_PATH"
        fi
    done

    echo
    info "Refreshing desktop/icon caches..."
    refresh_caches

    echo
    ok "Done! Created ${#P_NAME[@]} profile(s):"
    for i in "${!P_NAME[@]}"; do
        echo "   - ${P_NAME[$i]}  (class: brave-${P_SLUG[$i]})"
    done
    echo
    echo "Launch each one from your app menu / KRunner (search for the exact"
    echo "name you gave it), then right-click its taskbar icon and pin it. If"
    echo "icons/names don't show up immediately, log out and back in to force"
    echo "a full cache refresh."
}

# =============================================================================
# REMOVE
# =============================================================================

do_remove() {
    [[ -d "$APPS_DIR" ]] || { echo "No launcher directory found at $APPS_DIR"; return; }

    mapfile -t CANDIDATES < <(grep -lE '^StartupWMClass=brave-' "$APPS_DIR"/*.desktop 2>/dev/null)

    if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
        echo "No Brave profile launchers found under $APPS_DIR."
        return
    fi

    declare -a D_PATH=() D_NAME=() D_DATADIR=() D_ICON=()

    for f in "${CANDIDATES[@]}"; do
        name=$(grep -m1 '^Name=' "$f" | cut -d= -f2-)
        icon=$(grep -m1 '^Icon=' "$f" | cut -d= -f2-)
        exec_line=$(grep -m1 '^Exec=' "$f" | cut -d= -f2-)
        datadir=$(echo "$exec_line" | grep -oE -- '--user-data-dir=("[^"]*"|[^ ]*)' | sed -E 's/--user-data-dir=//; s/^"//; s/"$//')

        D_PATH+=("$f"); D_NAME+=("${name:-<unnamed>}")
        D_DATADIR+=("${datadir:-<unknown>}"); D_ICON+=("${icon:-}")
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
        for n in "${RAW[@]}"; do
            n=$(echo "$n" | tr -d '[:space:]')
            [[ "$n" =~ ^[0-9]+$ ]] || continue
            idx=$((n-1))
            (( idx >= 0 && idx < ${#D_PATH[@]} )) && INDICES+=("$idx")
        done
    fi

    [[ ${#INDICES[@]} -eq 0 ]] && { echo "Nothing selected, nothing removed."; return; }

    echo
    for idx in "${INDICES[@]}"; do
        name="${D_NAME[$idx]}"; dpath="${D_PATH[$idx]}"
        icon="${D_ICON[$idx]}"; datadir="${D_DATADIR[$idx]}"

        info "Removing launcher for '$name'"
        rm -f -- "$dpath" && ok "  removed $dpath"

        if [[ -n "$icon" && "$icon" == "$ICONS_DIR"/* && -f "$icon" ]]; then
            rm -f -- "$icon" && ok "  removed icon $icon"
        fi

        if [[ -n "$datadir" && "$datadir" != "<unknown>" && -d "$datadir" ]]; then
            echo
            warn "Profile data for '$name' still exists at: $datadir"
            read -r -p "  Delete this browsing data too? This is permanent. Type 'yes' to delete, anything else to keep: " CONFIRM
            if [[ "$CONFIRM" == "yes" ]]; then
                rm -rf -- "$datadir" && ok "  deleted $datadir"
            else
                echo "  Kept $datadir"
            fi
        fi
        echo
    done

    info "Refreshing desktop/icon caches..."
    refresh_caches
    ok "Done."
}

# =============================================================================
# Entry point
# =============================================================================

echo "Brave profile manager"
echo "======================"
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
