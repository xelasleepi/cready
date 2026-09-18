#!/usr/bin/env bash
#
# C / C++ Development Environment Bootstrapper -- Linux, WSL and macOS
# --------------------------------------------------------------------
# Written for students of Universite Sorbonne Paris Nord (Paris 13) who need
# an ANSI C toolchain for their coursework, but nothing here is specific to
# that university -- any student on any distro can run it.
#
# Installs and verifies:
#   * gcc, g++, gdb, make (and valgrind where available)
#   * Visual Studio Code + the C/C++ extension (optional)
#   * A verified test compile using ANSI C semantics with // comments
#
# This file is deliberately self-contained and exceeds the usual size limit for
# a source file. It has to be: it is fetched and executed in one piece by
# `curl | bash`, so it cannot source helpers that do not exist on the machine
# yet. Sections are separated by banner comments instead.
#
# Usage (remote):
#     curl -fsSL https://raw.githubusercontent.com/xelasleepi/cready/main/install.sh | bash
#
# Usage (local):
#     chmod +x install.sh && ./install.sh
#
# Non-interactive overrides:
#     CBOOT_PROFILE=c|cpp|full   what to install (skips the question)
#     CBOOT_EDITOR=vscode|kate|both|none   editor choice (skips the question)
#     CBOOT_ASSUME_YES=1         accept every default
#     CBOOT_STD=gnu89            standard used by the verification compile
#     CBOOT_SCAFFOLD_DIR=~/c-lab also create a starter project
#
set -uo pipefail

CBOOT_STD="${CBOOT_STD:-gnu89}"
CBOOT_ASSUME_YES="${CBOOT_ASSUME_YES:-0}"
CBOOT_PROFILE="${CBOOT_PROFILE:-}"
CBOOT_EDITOR="${CBOOT_EDITOR:-}"
CBOOT_SCAFFOLD_DIR="${CBOOT_SCAFFOLD_DIR:-}"

# CBOOT_STD is written into a generated Makefile, whose recipes run through a
# shell, and into tasks.json. An unvalidated value would therefore be a command
# and JSON injection vector, so only known GCC standard names are accepted.
case "$CBOOT_STD" in
    c89|c90|c99|c11|c17|c18|c23|gnu89|gnu90|gnu99|gnu11|gnu17|gnu18|gnu23) ;;
    *)
        printf 'Refusing to use CBOOT_STD=%s\n' "$CBOOT_STD" >&2
        printf 'Allowed: c89 c90 c99 c11 c17 c18 c23 gnu89 gnu90 gnu99 gnu11 gnu17 gnu18 gnu23\n' >&2
        exit 1
        ;;
esac

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi

step() { printf '\n%s[%s/%s] %s%s\n' "$C_CYAN" "$1" "$2" "$3" "$C_RESET"; }
ok()   { printf '      %sOK%s   %s\n' "$C_GREEN" "$C_RESET" "$1"; }
note() { printf '      %s..   %s%s\n' "$C_DIM" "$1" "$C_RESET"; }
warn() { printf '      %sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail() { printf '      %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$1"; }

die() { printf '\n'; fail "$1"; printf '\n'; exit 1; }

banner() {
    printf '\n'
    printf '%s  ===========================================%s\n' "$C_CYAN" "$C_RESET"
    printf '%s   C / C++ Development Environment Installer%s\n' "$C_CYAN" "$C_RESET"
    printf '%s  ===========================================%s\n' "$C_CYAN" "$C_RESET"
    printf '\n'
    printf '   Built for Universite Sorbonne Paris Nord (Paris 13)\n'
    printf '   students starting their ANSI C coursework.\n'
    printf '   %sNot affiliated with the university -- usable by anyone.%s\n' "$C_DIM" "$C_RESET"
    printf '\n'
}

# --------------------------------------------------------------------------
# Interaction
#
# When this script is run as `curl ... | bash`, stdin is the script itself,
# so `read` would consume the remaining source. Always read from /dev/tty.
# --------------------------------------------------------------------------

can_prompt() {
    [ "$CBOOT_ASSUME_YES" = "1" ] && return 1
    [ -r /dev/tty ] || return 1
    return 0
}

ask() {
    # ask <prompt> <default>
    # Only the answer may reach stdout; callers capture it with $(...).
    # Anything human-readable goes to stderr or /dev/tty, never stdout.
    local prompt="$1" default="$2" reply=''
    if ! can_prompt; then
        printf '      %s%s [auto: %s]%s\n' "$C_DIM" "$prompt" "$default" "$C_RESET" >&2
        printf '%s' "$default"
        return
    fi
    printf '   %s [%s]: ' "$prompt" "$default" > /dev/tty
    IFS= read -r reply < /dev/tty || reply=''
    [ -z "$reply" ] && reply="$default"
    printf '%s' "$reply"
}

confirm() {
    # confirm <prompt>  -> returns 0 for yes
    local answer
    answer="$(ask "$1 (y/n)" "y")"
    case "$answer" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
}

# Which editor(s) to set up. Only asked when the chosen profile includes one.
choose_editor() {
    if [ -n "$CBOOT_EDITOR" ]; then
        printf '%s' "$CBOOT_EDITOR"
        return
    fi

    printf '\n'
    printf '   Which editor do you want?\n\n'
    printf '     1) Visual Studio Code  - full IDE features, debugger, IntelliSense\n'
    printf '     2) Kate                - lightweight KDE editor, fast, simple\n'
    printf '     3) Both\n'
    printf '     4) Neither             - I already have one\n\n'

    case "$(ask 'Choose 1, 2, 3 or 4' '1')" in
        2) printf 'kate' ;;
        3) printf 'both' ;;
        4) printf 'none' ;;
        *) printf 'vscode' ;;
    esac
}

# --------------------------------------------------------------------------
# Platform detection
# --------------------------------------------------------------------------

OS_KIND=''        # linux | macos
IS_WSL=0
DISTRO_ID=''
DISTRO_NAME=''
PKG=''            # apt | dnf | yum | pacman | zypper | apk | brew
SUDO=''

detect_platform() {
    case "$(uname -s)" in
        Linux)  OS_KIND='linux' ;;
        Darwin) OS_KIND='macos' ;;
        MINGW*|MSYS*|CYGWIN*)
            # Git Bash / MSYS2 shell on Windows. This is a real Windows box,
            # not a Linux one, so the PowerShell installer is the right tool.
            printf '\n'
            fail "This is Windows ($(uname -s)), not Linux."
            printf '\n'
            printf '   Use the Windows installer instead, from PowerShell:\n\n'
            printf '     irm https://raw.githubusercontent.com/xelasleepi/cready/main/install.ps1 | iex\n\n'
            printf '   If you actually want a Linux toolchain on this machine,\n'
            printf '   install WSL first ("wsl --install"), then re-run this\n'
            printf '   script from inside your WSL distro.\n\n'
            exit 1
            ;;
        *)      die "Unsupported operating system: $(uname -s)" ;;
    esac

    # WSL reports a Microsoft-patched kernel.
    if [ "$OS_KIND" = 'linux' ] && grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
        IS_WSL=1
    fi

    if [ "$OS_KIND" = 'macos' ]; then
        DISTRO_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
        PKG='brew'
        if ! command -v brew >/dev/null 2>&1; then
            printf '\n'
            fail 'Homebrew is required on macOS but is not installed.'
            printf '\n'
            printf '   Install it first (one line, from https://brew.sh):\n\n'
            printf '     /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n\n'
            printf '   Then re-run this script.\n\n'
            exit 1
        fi
    elif [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
    else
        DISTRO_ID='unknown'
        DISTRO_NAME='unknown Linux'
    fi

    if [ "$OS_KIND" = 'linux' ]; then
        if   command -v apt-get >/dev/null 2>&1; then PKG='apt'
        elif command -v dnf     >/dev/null 2>&1; then PKG='dnf'
        elif command -v yum     >/dev/null 2>&1; then PKG='yum'
        elif command -v pacman  >/dev/null 2>&1; then PKG='pacman'
        elif command -v zypper  >/dev/null 2>&1; then PKG='zypper'
        elif command -v apk     >/dev/null 2>&1; then PKG='apk'
        else die "No supported package manager found (apt, dnf, yum, pacman, zypper, apk)."
        fi
    fi

    # Root already? Then sudo is unnecessary and often absent in containers.
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=''
    elif command -v sudo >/dev/null 2>&1; then
        SUDO='sudo'
    else
        die "This script needs root privileges but 'sudo' is not installed. Re-run as root."
    fi
}

# --------------------------------------------------------------------------
# Package installation
# --------------------------------------------------------------------------

pm_install() {
    # pm_install <packages...>
    case "$PKG" in
        apt)
            $SUDO apt-get update -qq
            # `env` so the variable survives sudo; a bare VAR=x prefix only
            # applies to sudo itself unless sudoers keeps it, and a debconf
            # prompt would hang a `curl | bash` run holding the dpkg lock.
            $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        dnf)    $SUDO dnf install -y "$@" ;;
        yum)    $SUDO yum install -y "$@" ;;
        # -Syu, never a bare -Sy: syncing the database without upgrading is
        # Arch's documented partial-upgrade trap and can pull in packages built
        # against libraries the system does not have yet.
        pacman) $SUDO pacman -Syu --needed --noconfirm "$@" ;;
        zypper) $SUDO zypper --non-interactive install "$@" ;;
        apk)    $SUDO apk add --no-cache "$@" ;;
        brew)   brew install "$@" ;;
        *)      die "Unknown package manager: $PKG" ;;
    esac
}

install_toolchain() {
    local want_cpp="$1" pkgs=()

    case "$PKG" in
        apt)
            # build-essential pulls gcc, g++, make and libc headers together.
            pkgs=(build-essential gdb)
            ;;
        dnf|yum)
            pkgs=(gcc make gdb glibc-devel)
            [ "$want_cpp" = "1" ] && pkgs+=(gcc-c++)
            ;;
        pacman)
            pkgs=(base-devel gdb)
            ;;
        zypper)
            pkgs=(gcc make gdb glibc-devel)
            [ "$want_cpp" = "1" ] && pkgs+=(gcc-c++)
            ;;
        apk)
            pkgs=(build-base gdb)
            ;;
        brew)
            pkgs=(gcc make)
            ;;
    esac

    note "Installing: ${pkgs[*]}"
    if ! pm_install "${pkgs[@]}"; then
        die "Package installation failed. Check your network and package manager, then re-run."
    fi
    ok "Compiler toolchain installed"

    # Homebrew deliberately does not symlink an unversioned gcc, so `gcc` keeps
    # resolving to Apple's clang wrapper. Say so plainly instead of reporting a
    # GCC install that the student will never actually invoke.
    if [ "$PKG" = 'brew' ]; then
        local real_gcc
        real_gcc="$(ls "$(brew --prefix 2>/dev/null)/bin"/gcc-[0-9]* 2>/dev/null | sort -V | tail -1)"
        if [ -n "$real_gcc" ]; then
            warn "On macOS, 'gcc' still runs Apple clang, not the GCC just installed."
            note "Real GCC is at: $real_gcc"
            note "Use it explicitly, e.g.  $(basename "$real_gcc") -std=$CBOOT_STD main.c -o main"
            note 'For coursework, Apple clang accepts the same flags and is usually fine.'
        fi
    fi

    # valgrind is standard in French university C courses for memory debugging,
    # but it is unavailable on some distros/architectures -- never fatal.
    if [ "$PKG" != 'brew' ]; then
        note 'Installing valgrind (optional memory checker)'
        if pm_install valgrind >/dev/null 2>&1; then
            ok 'valgrind installed'
        else
            warn 'valgrind unavailable on this system - skipping (not required)'
        fi
    fi
}

# --------------------------------------------------------------------------
# Visual Studio Code
# --------------------------------------------------------------------------

install_vscode() {
    if command -v code >/dev/null 2>&1; then
        ok "VS Code already installed ($(command -v code))"
        install_cpp_extension
        return
    fi

    # In WSL you do NOT install the Linux GUI build. You install VS Code on
    # Windows and connect into the distro with the WSL remote extension --
    # that is the supported setup and avoids a broken GUI stack.
    if [ "$IS_WSL" = "1" ]; then
        warn 'Running under WSL - do not install the Linux GUI build here.'
        note 'Install VS Code on WINDOWS instead:  https://code.visualstudio.com'
        note 'Then add the extension:  ms-vscode-remote.remote-wsl'
        note "Afterwards, run 'code .' from this shell to open your project."
        return
    fi

    case "$PKG" in
        apt)
            note 'Adding the Microsoft package repository'
            pm_install wget gpg apt-transport-https >/dev/null 2>&1 || true

            # mktemp, not a fixed /tmp name: /tmp is world-writable, so a
            # predictable filename lets another local user pre-create a symlink
            # and redirect this write, or swap the key before it is installed
            # into the root-owned trusted keyring.
            local keyfile
            keyfile="$(mktemp)" || { warn 'mktemp failed - skipping VS Code'; return; }

            # Every step is checked. A half-written key plus a live sources.list
            # entry would break `apt update` system-wide for the student, long
            # after this script has exited.
            if ! wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
                 | gpg --dearmor -o "$keyfile" 2>/dev/null || [ ! -s "$keyfile" ]; then
                rm -f "$keyfile"
                warn 'Could not download the Microsoft signing key - skipping VS Code'
                note 'Your apt configuration was left untouched.'
                return
            fi

            if ! $SUDO install -D -o root -g root -m 644 \
                 "$keyfile" /etc/apt/keyrings/packages.microsoft.gpg; then
                rm -f "$keyfile"
                warn 'Could not install the signing key - skipping VS Code'
                return
            fi
            rm -f "$keyfile"

            echo 'deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main' \
                | $SUDO tee /etc/apt/sources.list.d/vscode.list > /dev/null

            if ! pm_install code; then
                # Roll back rather than leaving a repo that breaks apt update.
                warn 'VS Code install failed - removing the repository entry again'
                $SUDO rm -f /etc/apt/sources.list.d/vscode.list \
                            /etc/apt/keyrings/packages.microsoft.gpg
                return
            fi
            ;;
        dnf|yum|zypper)
            note 'Adding the Microsoft package repository'
            if ! $SUDO rpm --import https://packages.microsoft.com/keys/microsoft.asc; then
                warn 'Could not import the Microsoft signing key - skipping VS Code'
                return
            fi

            # zypper reads /etc/zypp/repos.d; only dnf/yum use /etc/yum.repos.d.
            local repofile='/etc/yum.repos.d/vscode.repo'
            [ "$PKG" = 'zypper' ] && repofile='/etc/zypp/repos.d/vscode.repo'

            printf '[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\nautorefresh=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n' \
                | $SUDO tee "$repofile" > /dev/null

            if ! pm_install code; then
                warn 'VS Code install failed - removing the repository entry again'
                $SUDO rm -f "$repofile"
                return
            fi
            ;;
        pacman)
            # VS Code proper is not in the Arch repos (only the OSS build).
            # AUR packages are community-maintained and run arbitrary build
            # scripts, so this is never done unattended.
            warn 'VS Code on Arch comes from the AUR, which is community-maintained'
            note 'AUR packages run build scripts that nobody at Arch or Microsoft vetted.'
            if command -v yay >/dev/null 2>&1; then
                confirm 'Install visual-studio-code-bin from the AUR?' \
                    && { yay -S visual-studio-code-bin || warn 'AUR install failed'; } \
                    || { note 'Skipped'; return; }
            elif command -v paru >/dev/null 2>&1; then
                confirm 'Install visual-studio-code-bin from the AUR?' \
                    && { paru -S visual-studio-code-bin || warn 'AUR install failed'; } \
                    || { note 'Skipped'; return; }
            else
                note 'No AUR helper found. Install yay or paru, then: yay -S visual-studio-code-bin'
                note 'Or use the open-source build instead: sudo pacman -S code'
                return
            fi
            ;;
        apk)
            warn 'VS Code is not packaged for Alpine - install it manually if needed.'
            return
            ;;
        brew)
            brew install --cask visual-studio-code || { warn 'VS Code install failed'; return; }
            ;;
    esac

    if command -v code >/dev/null 2>&1; then
        ok 'VS Code installed'
        install_cpp_extension
    else
        warn 'VS Code did not end up on PATH - continuing without it'
    fi
}

install_kate() {
    if command -v kate >/dev/null 2>&1; then
        ok "Kate already installed ($(command -v kate))"
        install_clangd
        return
    fi

    # Kate is a GUI application. Under WSL that needs WSLg (Windows 11 or
    # recent Windows 10); without it the install succeeds but nothing renders.
    if [ "$IS_WSL" = "1" ]; then
        warn 'Kate is a GUI app and needs WSLg to display under WSL.'
        note 'On Windows 11 this works out of the box; on older builds it will not.'
        if ! confirm 'Install Kate inside WSL anyway?'; then
            note 'Skipped - consider installing Kate on Windows instead.'
            return
        fi
    fi

    note 'Installing Kate'
    if [ "$PKG" = 'brew' ]; then
        brew install --cask kate || { warn 'Kate install failed - continuing'; return; }
    elif ! pm_install kate; then
        warn 'Kate install failed - continuing'
        return
    fi

    if command -v kate >/dev/null 2>&1; then
        ok 'Kate installed'
        install_clangd
    else
        warn 'Kate did not end up on PATH - continuing without it'
    fi
}

# Kate has no built-in C parser; its LSP plugin drives clangd. Best-effort
# only, since Kate is still a usable editor without it.
install_clangd() {
    if command -v clangd >/dev/null 2>&1; then
        ok 'clangd already installed'
        return
    fi

    local pkg='clangd'
    case "$PKG" in
        dnf|yum)  pkg='clang-tools-extra' ;;
        pacman)   pkg='clang' ;;
        zypper)   pkg='clang-tools' ;;
        apk)      pkg='clang-extra-tools' ;;
        brew)     pkg='llvm' ;;
    esac

    note "Installing $pkg for Kate code completion"
    if pm_install "$pkg" >/dev/null 2>&1 && command -v clangd >/dev/null 2>&1; then
        ok 'clangd installed - enable the LSP Client plugin in Kate'
    else
        warn 'clangd unavailable - Kate still works, just without completion'
    fi
}

install_cpp_extension() {
    note 'Ensuring the C/C++ extension is present'
    if code --list-extensions 2>/dev/null | grep -qx 'ms-vscode.cpptools'; then
        ok 'Extension ms-vscode.cpptools already installed'
    elif code --install-extension ms-vscode.cpptools --force >/dev/null 2>&1; then
        ok 'Extension ms-vscode.cpptools installed'
    else
        warn 'Could not install the C/C++ extension automatically'
    fi
}

# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------

verify_toolchain() {
    local want_cpp="$1"
    local work
    work="$(mktemp -d)"
    # EXIT as well as RETURN: die() calls exit directly, which would otherwise
    # bypass a RETURN-only trap and leave the scratch directory behind.
    trap 'rm -rf "$work"' RETURN EXIT

    command -v gcc >/dev/null 2>&1 || die 'gcc is not on PATH after installation.'

    # Mixes ANSI block comments with // line comments, so a pass proves the
    # configured standard accepts both styles.
    cat > "$work/verify.c" <<'CSRC'
#include <stdio.h>

/* ANSI C style block comment */
int main(void)
{
    int value = 42;   // line comment - rejected by strict c89
    printf("TOOLCHAIN_OK %d\n", value);
    return 0;
}
CSRC

    if ! gcc -std="$CBOOT_STD" -Wall -Wextra "$work/verify.c" -o "$work/verify"; then
        die "Verification compile failed under -std=$CBOOT_STD."
    fi
    if ! "$work/verify" | grep -q 'TOOLCHAIN_OK 42'; then
        die 'Verification binary produced unexpected output.'
    fi
    ok "Compiled and ran a C program using -std=$CBOOT_STD"
    ok 'Both /* */ and // comment styles accepted'

    if [ "$want_cpp" = "1" ] && ! command -v g++ >/dev/null 2>&1; then
        warn 'g++ not found - skipping the C++ check'
        note 'You chose a C++ profile, so re-run and allow the install to repair it.'
        return 0
    fi

    if [ "$want_cpp" = "1" ] && command -v g++ >/dev/null 2>&1; then
        cat > "$work/verify.cpp" <<'CPPSRC'
#include <iostream>
#include <vector>
int main() {
    std::vector<int> v{1, 2, 3};
    for (int i : v) std::cout << i;
    std::cout << " CPP_OK\n";
}
CPPSRC
        if g++ -std=c++17 "$work/verify.cpp" -o "$work/verifycpp" \
           && "$work/verifycpp" | grep -q 'CPP_OK'; then
            ok 'C++ toolchain verified (-std=c++17)'
        else
            warn 'C++ verification failed'
        fi
    fi
}

# --------------------------------------------------------------------------
# Starter project
# --------------------------------------------------------------------------

create_scaffold() {
    local dir="$1"
    mkdir -p "$dir/.vscode"

    # Never overwrite. CBOOT_SCAFFOLD_DIR is just a path, so it is easy to aim
    # at a real project by accident; silently replacing a tuned Makefile or
    # launch.json would destroy the student's work.
    write_if_absent() {
        local target="$1"
        if [ -e "$target" ]; then
            note "Kept existing $(basename "$target")"
            cat > /dev/null   # drain the heredoc on stdin
            return
        fi
        cat > "$target"
    }

    if [ ! -f "$dir/main.c" ]; then
        cat > "$dir/main.c" <<'CSRC'
#include <stdio.h>

/* ANSI C with // comments enabled via -std=gnu89 */
int main(void)
{
    printf("Hello, C!\n");   // press F5 to build and debug
    return 0;
}
CSRC
    fi

    write_if_absent "$dir/Makefile" <<MAKEFILE
CC      = gcc
CFLAGS  = -std=$CBOOT_STD -Wall -Wextra -g
TARGET  = main
SOURCES = main.c

\$(TARGET): \$(SOURCES)
	\$(CC) \$(CFLAGS) \$(SOURCES) -o \$(TARGET)

run: \$(TARGET)
	./\$(TARGET)

clean:
	rm -f \$(TARGET)

.PHONY: run clean
MAKEFILE

    write_if_absent "$dir/.vscode/tasks.json" <<TASKS
{
  "version": "2.0.0",
  "tasks": [
    {
      "type": "cppbuild",
      "label": "build active file",
      "command": "gcc",
      "args": [
        "-std=$CBOOT_STD",
        "-Wall",
        "-Wextra",
        "-g",
        "\${file}",
        "-o",
        "\${fileDirname}/\${fileBasenameNoExtension}"
      ],
      "options": { "cwd": "\${fileDirname}" },
      "problemMatcher": ["\$gcc"],
      "group": { "kind": "build", "isDefault": true }
    }
  ]
}
TASKS

    write_if_absent "$dir/.vscode/launch.json" <<'LAUNCH'
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug active file",
      "type": "cppdbg",
      "request": "launch",
      "program": "${fileDirname}/${fileBasenameNoExtension}",
      "args": [],
      "stopAtEntry": false,
      "cwd": "${fileDirname}",
      "externalConsole": false,
      "MIMode": "gdb",
      "preLaunchTask": "build active file"
    }
  ]
}
LAUNCH

    write_if_absent "$dir/.vscode/c_cpp_properties.json" <<'PROPS'
{
  "version": 4,
  "configurations": [
    {
      "name": "Linux-GCC",
      "includePath": ["${workspaceFolder}/**"],
      "compilerPath": "/usr/bin/gcc",
      "cStandard": "c89",
      "cppStandard": "c++17",
      "intelliSenseMode": "linux-gcc-x64"
    }
  ]
}
PROPS

    ok "Starter project created at $dir"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
    banner
    detect_platform

    local where="$DISTRO_NAME"
    [ "$IS_WSL" = "1" ] && where="$where (WSL -- Linux inside Windows)"
    printf '   Detected: %s\n' "$where"
    printf '   Packages: %s\n\n' "$PKG"

    # --- What is this for? ---
    local profile="$CBOOT_PROFILE"
    if [ -z "$profile" ]; then
        printf '   What do you need this machine set up for?\n\n'
        printf '     1) C only        - ANSI C coursework (gcc, gdb, make)\n'
        printf '     2) C and C++     - adds the g++ compiler\n'
        printf '     3) Full setup    - C, C++, and an editor\n\n'
        case "$(ask 'Choose 1, 2 or 3' '3')" in
            1) profile='c' ;;
            2) profile='cpp' ;;
            *) profile='full' ;;
        esac
    fi

    local want_cpp=0 want_editor=0
    case "$profile" in
        c)    want_cpp=0; want_editor=0 ;;
        cpp)  want_cpp=1; want_editor=0 ;;
        full) want_cpp=1; want_editor=1 ;;
        *)    die "Unknown profile '$profile' (expected c, cpp or full)" ;;
    esac

    local editor='none' want_vscode=0 want_kate=0
    if [ "$want_editor" = "1" ]; then
        editor="$(choose_editor)"
        case "$editor" in
            vscode) want_vscode=1 ;;
            kate)   want_kate=1 ;;
            both)   want_vscode=1; want_kate=1 ;;
            none)   ;;
            *)      die "Unknown editor '$editor' (expected vscode, kate, both or none)" ;;
        esac
    fi

    local total=3
    [ "$want_vscode" = "1" ] && total=$((total + 1))
    [ "$want_kate" = "1" ]   && total=$((total + 1))
    [ -n "$CBOOT_SCAFFOLD_DIR" ] && total=$((total + 1))

    step 1 "$total" 'Checking for an existing toolchain'
    if command -v gcc >/dev/null 2>&1; then
        ok "Found: $(command -v gcc)"
        ok "$(gcc --version | head -1)"
        if ! confirm 'gcc is already installed. Reinstall/repair anyway?'; then
            note 'Keeping the existing toolchain'
            step 2 "$total" 'Skipping installation'
        else
            step 2 "$total" 'Installing the compiler toolchain'
            install_toolchain "$want_cpp"
        fi
    else
        note 'No gcc found - will install'
        step 2 "$total" 'Installing the compiler toolchain'
        install_toolchain "$want_cpp"
    fi

    local next=3
    if [ "$want_vscode" = "1" ]; then
        step "$next" "$total" 'Installing Visual Studio Code'
        install_vscode
        next=$((next + 1))
    fi

    if [ "$want_kate" = "1" ]; then
        step "$next" "$total" 'Installing Kate'
        install_kate
        next=$((next + 1))
    fi

    if [ -n "$CBOOT_SCAFFOLD_DIR" ]; then
        step "$next" "$total" 'Creating the starter project'
        create_scaffold "$CBOOT_SCAFFOLD_DIR"
        next=$((next + 1))
    fi

    step "$next" "$total" 'Verifying'
    verify_toolchain "$want_cpp"

    # --- Report ---
    printf '\n'
    printf '%s  ===========================================%s\n' "$C_GREEN" "$C_RESET"
    printf '%s   Installation complete%s\n' "$C_GREEN" "$C_RESET"
    printf '%s  ===========================================%s\n' "$C_GREEN" "$C_RESET"
    printf '\n'
    for tool in gcc g++ gdb make valgrind clangd code kate; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf '   %-10s %s\n' "$tool" "$(command -v "$tool")"
        else
            printf '   %-10s %s-%s\n' "$tool" "$C_DIM" "$C_RESET"
        fi
    done
    printf '\n'
    printf '%s   Compile and run:%s\n' "$C_CYAN" "$C_RESET"
    printf '     gcc -std=%s -Wall hello.c -o hello\n' "$CBOOT_STD"
    printf '     ./hello\n'
    printf '\n'
}

main "$@"
