#!/bin/bash

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wine_commit="81d78e4f3ea8ce868d775021fdc9f90122dc1a6b"
patch_file="$project_dir/patches/0001-ntdll-support-msg-waitall.patch"
source_dir="$project_dir/build/wine"
build_dir="$project_dir/build/wine64"
output_dir="$project_dir/output"
patched_ntdll="$output_dir/ntdll.so"
relative_ntdll="files/lib/wine/x86_64-unix/ntdll.so"

usage()
{
    echo "Usage:"
    echo "  $0"
    echo "  $0 setup BASE_PROTON_DIR CUSTOM_PROTON_DIR"
    echo "  $0 run CUSTOM_PROTON_DIR COMPAT_DATA_DIR PRISM_EXE LOADER_EXE"
    echo "  $0 all BASE_PROTON_DIR CUSTOM_PROTON_DIR COMPAT_DATA_DIR PRISM_EXE LOADER_EXE"
}

prompt_path()
{
    local label="$1" default_value="${2:-}"

    reply=""

    if [[ -n "$default_value" ]]; then
        read -e -r -p "$label [$default_value]: " reply
        reply="${reply:-$default_value}"
    else
        while [[ -z "${reply:-}" ]]; do
            read -e -r -p "$label: " reply
        done
    fi
}

detect_base_proton()
{
    local candidate library vdf

    if [[ -n "${PROTON_BASE:-}" && -f "$PROTON_BASE/$relative_ntdll" ]]; then
        echo "$PROTON_BASE"
        return 0
    fi

    for candidate in \
        "$HOME/.steam/steam/steamapps/common/Proton 11.0" \
        "$HOME/.local/share/Steam/steamapps/common/Proton 11.0"
    do
        if [[ -f "$candidate/$relative_ntdll" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    for vdf in \
        "$HOME/.steam/steam/steamapps/libraryfolders.vdf" \
        "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"
    do
        [[ -f "$vdf" ]] || continue
        while IFS= read -r library; do
            candidate="$library/steamapps/common/Proton 11.0"
            if [[ -f "$candidate/$relative_ntdll" ]]; then
                echo "$candidate"
                return 0
            fi
        done < <(sed -nE 's/^[[:space:]]*"path"[[:space:]]*"([^"]+)".*/\1/p' "$vdf")
    done

    return 1
}

build_ntdll()
{
    if [[ -f "$patched_ntdll" ]]; then
        echo "Using existing build: $patched_ntdll"
        sha256sum "$patched_ntdll"
        return 0
    fi

    if [[ ! -d "$source_dir/.git" ]]; then
        mkdir -p "$(dirname "$source_dir")"
        git clone --depth 1 --branch proton_11.0 https://github.com/ValveSoftware/wine.git "$source_dir"
    fi

    if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$wine_commit" ]]; then
        if [[ -n "$(git -C "$source_dir" status --porcelain)" ]]; then
            echo "Wine source tree is not clean and is on the wrong commit." >&2
            exit 1
        fi
        git -C "$source_dir" fetch --depth 1 origin "$wine_commit"
        git -C "$source_dir" checkout "$wine_commit"
    fi

    if git -C "$source_dir" apply --check "$patch_file" 2>/dev/null; then
        git -C "$source_dir" apply "$patch_file"
    elif ! git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
        echo "Patch cannot be applied cleanly." >&2
        exit 1
    fi

    (
        cd "$source_dir"
        ./tools/make_requests
        ./tools/make_specfiles
        (
            cd dlls/winevulkan
            ./make_vulkan -x vk.xml -X video.xml
        )
        autoreconf -f
    )

    mkdir -p "$build_dir" "$output_dir"
    (
        cd "$build_dir"
        "$source_dir/configure" --enable-win64 --disable-tests --without-unwind
        make -j"${BUILD_JOBS:-$(nproc)}" dlls/ntdll/ntdll.so
    )

    cp "$build_dir/dlls/ntdll/ntdll.so" "$patched_ntdll"
    strip --strip-debug "$patched_ntdll"
    sha256sum "$patched_ntdll"
}

install_proton()
{
    local base_proton custom_proton target

    base_proton="$(realpath "$1")"
    custom_proton="$2"

    if [[ ! -f "$base_proton/$relative_ntdll" ]]; then
        echo "Base Proton ntdll.so not found." >&2
        exit 1
    fi

    if [[ ! -f "$patched_ntdll" ]]; then
        build_ntdll
    fi

    if [[ -e "$custom_proton" ]]; then
        echo "Destination already exists: $custom_proton" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$custom_proton")"
    cp -a --reflink=auto "$base_proton" "$custom_proton"
    target="$custom_proton/$relative_ntdll"
    cp "$target" "$target.original"
    chmod u+w "$target"
    cp "$patched_ntdll" "$target"
    chmod u-w "$target"

    echo "Custom Proton created at: $custom_proton"
    sha256sum "$target" "$target.original"
}

run_programs()
{
    local proton_dir compat_data prism_exe loader_exe app_id prism_pid

    proton_dir="$(realpath "$1")"
    compat_data="$(realpath -m "$2")"
    prism_exe="$(realpath "$3")"
    loader_exe="$(realpath "$4")"
    app_id="${APP_ID:-2214401925}"

    mkdir -p "$compat_data"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.steam/steam}"
    export STEAM_COMPAT_DATA_PATH="$compat_data"
    export WINEPREFIX="$compat_data/pfx"
    export SteamAppId="$app_id"
    export SteamGameId="$app_id"

    "$proton_dir/proton" run "$prism_exe" &
    prism_pid=$!
    echo "Prism started with PID $prism_pid."
    "$proton_dir/proton" run "$loader_exe" &
    echo "Vape started with PID $!."
}

interactive_menu()
{
    local choice reply base_proton custom_proton compat_data prism_exe loader_exe
    local default_base
    local default_custom="$HOME/.local/share/vape2linux/Proton-11-MSGWAITALL"
    local default_compat="$HOME/.local/share/vape2linux/compatdata"

    default_base="$(detect_base_proton || true)"

    clear 2>/dev/null || true
    echo "Vape2Linux"
    echo
    echo "1) Start game :)"
    echo "2) Setup"
    echo "q) Quit"
    echo
    read -r -p "Select an option: " choice

    case "$choice" in
        1)
            prompt_path "Custom Proton directory" "$default_custom"
            custom_proton="$reply"
            prompt_path "Compatibility-data directory" "$default_compat"
            compat_data="$reply"
            prompt_path "Prism Launcher Windows (Portable) executable"
            prism_exe="$reply"
            prompt_path "Vape executable"
            loader_exe="$reply"
            run_programs "$custom_proton" "$compat_data" "$prism_exe" "$loader_exe"
            ;;
        2)
            prompt_path "Base Proton 11.0 directory" "$default_base"
            base_proton="$reply"
            prompt_path "New custom Proton directory" "$default_custom"
            custom_proton="$reply"
            build_ntdll
            install_proton "$base_proton" "$custom_proton"
            ;;
        q|Q)
            exit 0
            ;;
        *)
            echo "Invalid option." >&2
            exit 2
            ;;
    esac
}

command="${1:-}"

case "$command" in
    "")
        interactive_menu
        ;;
    setup)
        [[ $# -eq 3 ]] || { usage; exit 2; }
        build_ntdll
        install_proton "$2" "$3"
        ;;
    run)
        [[ $# -eq 5 ]] || { usage; exit 2; }
        run_programs "$2" "$3" "$4" "$5"
        ;;
    all)
        [[ $# -eq 6 ]] || { usage; exit 2; }
        build_ntdll
        install_proton "$2" "$3"
        run_programs "$3" "$4" "$5" "$6"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage
        exit 2
        ;;
esac
