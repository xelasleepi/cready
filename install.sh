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
#   * Visual Studio Code and/or Kate, with cpptools and clangd
#   * A verified test compile using ANSI C semantics with // comments
#
# Speaks English and French. The language follows your locale and can be
# forced with CBOOT_LANG.
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
#     CBOOT_LANG=fr              force French (auto-detected from $LANG)
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
CBOOT_LANG="${CBOOT_LANG:-}"

# Follow the user's locale unless told otherwise. A French student on a French
# system should not have to know an environment variable exists.
if [ -z "$CBOOT_LANG" ]; then
    case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
        fr*|FR*) CBOOT_LANG='fr' ;;
        *)       CBOOT_LANG='en' ;;
    esac
fi
CBOOT_LANG="$(printf '%s' "$CBOOT_LANG" | tr '[:upper:]' '[:lower:]')"
case "$CBOOT_LANG" in
    en|fr) ;;
    *)
        printf 'Unknown CBOOT_LANG=%s (expected en or fr)\n' "$CBOOT_LANG" >&2
        exit 1
        ;;
esac

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
# Messages
#
# One entry per key, English and French side by side so they cannot drift
# apart. A plain case statement rather than an associative array, because
# macOS still ships bash 3.2, which has no `declare -A`.
#
# Messages use %s placeholders only; never embed a literal % or a newline.
# --------------------------------------------------------------------------

msg() {
    local key="$1"; shift
    local en='' fr=''
    case "$key" in
    # -- banner / framing -------------------------------------------------
    title)          en="C / C++ Development Environment Installer"
                    fr="Installateur d'environnement de développement C / C++" ;;
    built_for)      en="Built for Universite Sorbonne Paris Nord (Paris 13)"
                    fr="Conçu pour les étudiants de l'Université Sorbonne" ;;
    built_for2)     en="students starting their ANSI C coursework."
                    fr="Paris Nord (Paris 13) qui débutent en C ANSI." ;;
    not_affiliated) en="Not affiliated with the university -- usable by anyone."
                    fr="Sans lien avec l'université -- utilisable par tous." ;;
    detected)       en="Detected: %s"
                    fr="Détecté : %s" ;;
    packages)       en="Packages: %s"
                    fr="Paquets : %s" ;;
    wsl_suffix)     en="%s (WSL -- Linux inside Windows)"
                    fr="%s (WSL -- Linux dans Windows)" ;;

    # -- questions --------------------------------------------------------
    q_profile)      en="What do you need this machine set up for?"
                    fr="Pour quel usage voulez-vous configurer cette machine ?" ;;
    q_profile_1)    en="  1) C only        - ANSI C coursework (gcc, gdb, make)"
                    fr="  1) C uniquement  - TP de C ANSI (gcc, gdb, make)" ;;
    q_profile_2)    en="  2) C and C++     - adds the g++ compiler"
                    fr="  2) C et C++      - ajoute le compilateur g++" ;;
    q_profile_3)    en="  3) Full setup    - C, C++, and an editor"
                    fr="  3) Complet       - C, C++ et un éditeur" ;;
    q_choose_123)   en="Choose 1, 2 or 3"
                    fr="Choisissez 1, 2 ou 3" ;;
    q_editor)       en="Which editor do you want?"
                    fr="Quel éditeur voulez-vous ?" ;;
    q_editor_1)     en="  1) Visual Studio Code  - full IDE features, debugger, IntelliSense"
                    fr="  1) Visual Studio Code  - IDE complet, débogueur, IntelliSense" ;;
    q_editor_2)     en="  2) Kate                - lightweight KDE editor, fast, simple"
                    fr="  2) Kate                - éditeur KDE léger, rapide, simple" ;;
    q_editor_3)     en="  3) Both"
                    fr="  3) Les deux" ;;
    q_editor_4)     en="  4) Neither             - I already have one"
                    fr="  4) Aucun               - j'en ai déjà un" ;;
    q_choose_1234)  en="Choose 1, 2, 3 or 4"
                    fr="Choisissez 1, 2, 3 ou 4" ;;
    q_yn)           en="%s (y/n)"
                    fr="%s (o/n)" ;;
    q_reinstall)    en="gcc is already installed. Reinstall/repair anyway?"
                    fr="gcc est déjà installé. Réinstaller/réparer quand même ?" ;;

    # -- steps ------------------------------------------------------------
    s_check)        en="Checking for an existing toolchain"
                    fr="Recherche d'une chaîne d'outils existante" ;;
    s_install)      en="Installing the compiler toolchain"
                    fr="Installation de la chaîne d'outils" ;;
    s_skip)         en="Skipping installation"
                    fr="Installation ignorée" ;;
    s_vscode)       en="Installing Visual Studio Code"
                    fr="Installation de Visual Studio Code" ;;
    s_kate)         en="Installing Kate"
                    fr="Installation de Kate" ;;
    s_scaffold)     en="Creating the starter project"
                    fr="Création du projet de départ" ;;
    s_verify)       en="Verifying"
                    fr="Vérification" ;;

    # -- toolchain --------------------------------------------------------
    found)          en="Found: %s"
                    fr="Trouvé : %s" ;;
    no_gcc)         en="No gcc found - will install"
                    fr="gcc introuvable - installation prévue" ;;
    keeping)        en="Keeping the existing toolchain"
                    fr="Conservation de la chaîne d'outils existante" ;;
    installing)     en="Installing: %s"
                    fr="Installation : %s" ;;
    tc_installed)   en="Compiler toolchain installed"
                    fr="Chaîne d'outils installée" ;;
    tc_failed)      en="Package installation failed. Check your network and package manager, then re-run."
                    fr="Échec de l'installation des paquets. Vérifiez votre réseau et votre gestionnaire de paquets, puis relancez." ;;
    vg_installing)  en="Installing valgrind (optional memory checker)"
                    fr="Installation de valgrind (vérificateur mémoire optionnel)" ;;
    vg_ok)          en="valgrind installed"
                    fr="valgrind installé" ;;
    vg_no)          en="valgrind unavailable on this system - skipping (not required)"
                    fr="valgrind indisponible sur ce système - ignoré (non requis)" ;;
    mac_clang)      en="On macOS, 'gcc' still runs Apple clang, not the GCC just installed."
                    fr="Sous macOS, 'gcc' lance toujours clang d'Apple, pas le GCC installé." ;;
    mac_real)       en="Real GCC is at: %s"
                    fr="Le vrai GCC se trouve ici : %s" ;;
    mac_use)        en="Use it explicitly, e.g.  %s -std=%s main.c -o main"
                    fr="Utilisez-le explicitement, ex.  %s -std=%s main.c -o main" ;;
    mac_fine)       en="For coursework, Apple clang accepts the same flags and is usually fine."
                    fr="Pour les TP, clang accepte les mêmes options et convient généralement." ;;

    # -- editors ----------------------------------------------------------
    vscode_have)    en="VS Code already installed (%s)"
                    fr="VS Code est déjà installé (%s)" ;;
    vscode_ok)      en="VS Code installed"
                    fr="VS Code installé" ;;
    vscode_fail)    en="VS Code install failed - continuing"
                    fr="Échec de l'installation de VS Code - on continue" ;;
    ms_repo)        en="Adding the Microsoft package repository"
                    fr="Ajout du dépôt de paquets Microsoft" ;;
    key_fail)       en="Could not download the Microsoft signing key - skipping VS Code"
                    fr="Impossible de télécharger la clé Microsoft - VS Code ignoré" ;;
    key_untouched)  en="Your apt configuration was left untouched."
                    fr="Votre configuration apt n'a pas été modifiée." ;;
    key_inst_fail)  en="Could not install the signing key - skipping VS Code"
                    fr="Impossible d'installer la clé de signature - VS Code ignoré" ;;
    repo_rollback)  en="VS Code install failed - removing the repository entry again"
                    fr="Échec de VS Code - suppression du dépôt ajouté" ;;
    mktemp_fail)    en="mktemp failed - skipping VS Code"
                    fr="Échec de mktemp - VS Code ignoré" ;;
    aur_warn)       en="VS Code on Arch comes from the AUR, which is community-maintained"
                    fr="Sur Arch, VS Code vient de l'AUR, maintenu par la communauté" ;;
    aur_note)       en="AUR packages run build scripts that nobody at Arch or Microsoft vetted."
                    fr="Les paquets AUR exécutent des scripts que ni Arch ni Microsoft n'ont validés." ;;
    aur_ask)        en="Install visual-studio-code-bin from the AUR?"
                    fr="Installer visual-studio-code-bin depuis l'AUR ?" ;;
    aur_fail)       en="AUR install failed"
                    fr="Échec de l'installation AUR" ;;
    aur_helper)     en="No AUR helper found. Install yay or paru, then: yay -S visual-studio-code-bin"
                    fr="Aucun assistant AUR. Installez yay ou paru, puis : yay -S visual-studio-code-bin" ;;
    aur_oss)        en="Or use the open-source build instead: sudo pacman -S code"
                    fr="Ou utilisez la version open source : sudo pacman -S code" ;;
    skipped)        en="Skipped"
                    fr="Ignoré" ;;
    ext_check)      en="Ensuring the C/C++ extension is present"
                    fr="Vérification de l'extension C/C++" ;;
    ext_have)       en="Extension ms-vscode.cpptools already installed"
                    fr="Extension ms-vscode.cpptools déjà installée" ;;
    ext_ok)         en="Extension ms-vscode.cpptools installed"
                    fr="Extension ms-vscode.cpptools installée" ;;
    ext_fail)       en="Could not install the C/C++ extension automatically"
                    fr="Impossible d'installer l'extension C/C++ automatiquement" ;;
    wsl_gui)        en="Running under WSL - do not install the Linux GUI build here."
                    fr="Vous êtes sous WSL - n'installez pas la version graphique Linux ici." ;;
    wsl_win)        en="Install VS Code on WINDOWS instead:  https://code.visualstudio.com"
                    fr="Installez plutôt VS Code sous WINDOWS :  https://code.visualstudio.com" ;;
    wsl_ext)        en="Then add the extension:  ms-vscode-remote.remote-wsl"
                    fr="Puis ajoutez l'extension :  ms-vscode-remote.remote-wsl" ;;
    wsl_code)       en="Afterwards, run 'code .' from this shell to open your project."
                    fr="Ensuite, lancez 'code .' depuis ce terminal pour ouvrir votre projet." ;;
    kate_have)      en="Kate already installed (%s)"
                    fr="Kate est déjà installé (%s)" ;;
    kate_ok)        en="Kate installed"
                    fr="Kate installé" ;;
    kate_fail)      en="Kate install failed - continuing"
                    fr="Échec de l'installation de Kate - on continue" ;;
    kate_installing) en="Installing Kate"
                    fr="Installation de Kate" ;;
    kate_nopath)    en="Kate did not end up on PATH - continuing without it"
                    fr="Kate n'est pas dans le PATH - on continue sans lui" ;;
    kate_wslg)      en="Kate is a GUI app and needs WSLg to display under WSL."
                    fr="Kate est une application graphique et nécessite WSLg sous WSL." ;;
    kate_wslg2)     en="On Windows 11 this works out of the box; on older builds it will not."
                    fr="Sous Windows 11 cela fonctionne directement ; pas sur les versions plus anciennes." ;;
    kate_wslg_ask)  en="Install Kate inside WSL anyway?"
                    fr="Installer Kate dans WSL malgré tout ?" ;;
    kate_wslg_skip) en="Skipped - consider installing Kate on Windows instead."
                    fr="Ignoré - envisagez d'installer Kate sous Windows." ;;
    clangd_have)    en="clangd already installed"
                    fr="clangd est déjà installé" ;;
    clangd_inst)    en="Installing %s for Kate code completion"
                    fr="Installation de %s pour la complétion dans Kate" ;;
    clangd_ok)      en="clangd installed - enable the LSP Client plugin in Kate"
                    fr="clangd installé - activez le plugin LSP Client dans Kate" ;;
    clangd_no)      en="clangd unavailable - Kate still works, just without completion"
                    fr="clangd indisponible - Kate fonctionne, mais sans complétion" ;;

    # -- verification -----------------------------------------------------
    v_nogcc)        en="gcc is not on PATH after installation."
                    fr="gcc n'est pas dans le PATH après l'installation." ;;
    v_cfail)        en="Verification compile failed under -std=%s."
                    fr="Échec de la compilation de vérification avec -std=%s." ;;
    v_badout)       en="Verification binary produced unexpected output."
                    fr="Le programme de vérification a produit une sortie inattendue." ;;
    v_cok)          en="Compiled and ran a C program using -std=%s"
                    fr="Programme C compilé et exécuté avec -std=%s" ;;
    v_comments)     en="Both /* */ and // comment styles accepted"
                    fr="Les commentaires /* */ et // sont tous deux acceptés" ;;
    v_nogpp)        en="g++ not found - skipping the C++ check"
                    fr="g++ introuvable - vérification C++ ignorée" ;;
    v_nogpp2)       en="You chose a C++ profile, so re-run and allow the install to repair it."
                    fr="Vous avez choisi un profil C++ : relancez et autorisez la réparation." ;;
    v_cppok)        en="C++ toolchain verified (-std=c++17)"
                    fr="Chaîne d'outils C++ vérifiée (-std=c++17)" ;;
    v_cppfail)      en="C++ verification failed"
                    fr="Échec de la vérification C++" ;;

    # -- scaffold ---------------------------------------------------------
    sc_kept)        en="Kept existing %s"
                    fr="Fichier %s conservé" ;;
    sc_ok)          en="Starter project created at %s"
                    fr="Projet de départ créé dans %s" ;;

    # -- platform / errors ------------------------------------------------
    e_windows)      en="This is Windows (%s), not Linux."
                    fr="Vous êtes sous Windows (%s), pas sous Linux." ;;
    e_win_use)      en="Use the Windows installer instead, from PowerShell:"
                    fr="Utilisez plutôt l'installateur Windows, depuis PowerShell :" ;;
    e_win_wsl)      en="If you actually want a Linux toolchain on this machine,"
                    fr="Si vous voulez vraiment une chaîne d'outils Linux ici," ;;
    e_win_wsl2)     en="install WSL first (\"wsl --install\"), then re-run this"
                    fr="installez d'abord WSL (\"wsl --install\"), puis relancez" ;;
    e_win_wsl3)     en="script from inside your WSL distro."
                    fr="ce script depuis votre distribution WSL." ;;
    e_os)           en="Unsupported operating system: %s"
                    fr="Système d'exploitation non pris en charge : %s" ;;
    e_nopm)         en="No supported package manager found (apt, dnf, yum, pacman, zypper, apk)."
                    fr="Aucun gestionnaire de paquets reconnu (apt, dnf, yum, pacman, zypper, apk)." ;;
    e_nosudo)       en="This script needs root privileges but 'sudo' is not installed. Re-run as root."
                    fr="Ce script nécessite les droits root mais 'sudo' est absent. Relancez en root." ;;
    e_nobrew)       en="Homebrew is required on macOS but is not installed."
                    fr="Homebrew est requis sous macOS mais n'est pas installé." ;;
    e_brew_get)     en="Install it first (one line, from https://brew.sh):"
                    fr="Installez-le d'abord (une ligne, depuis https://brew.sh) :" ;;
    e_rerun)        en="Then re-run this script."
                    fr="Puis relancez ce script." ;;
    e_profile)      en="Unknown profile '%s' (expected c, cpp or full)"
                    fr="Profil inconnu '%s' (attendu : c, cpp ou full)" ;;
    e_editor)       en="Unknown editor '%s' (expected vscode, kate, both or none)"
                    fr="Éditeur inconnu '%s' (attendu : vscode, kate, both ou none)" ;;
    e_pm)           en="Unknown package manager: %s"
                    fr="Gestionnaire de paquets inconnu : %s" ;;

    # -- summary ----------------------------------------------------------
    done_title)     en="Installation complete"
                    fr="Installation terminée" ;;
    compile_run)    en="Compile and run:"
                    fr="Compiler et exécuter :" ;;
    *)              en="$key"; fr="$key" ;;
    esac

    if [ "$CBOOT_LANG" = 'fr' ] && [ -n "$fr" ]; then
        # shellcheck disable=SC2059
        printf "$fr" "$@"
    else
        # shellcheck disable=SC2059
        printf "$en" "$@"
    fi
}

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

# Scratch directory used by the verification step. It is a global with an
# EXIT trap rather than a function-local with a RETURN trap, because die()
# calls exit directly: a RETURN trap would never fire, and a local would be
# out of scope by the time an EXIT trap ran, tripping `set -u`.
CBOOT_WORK=''
cleanup_work() {
    if [ -n "${CBOOT_WORK:-}" ] && [ -d "${CBOOT_WORK:-}" ]; then
        rm -rf "$CBOOT_WORK"
    fi
    CBOOT_WORK=''
}
trap cleanup_work EXIT

banner() {
    printf '\n'
    printf '%s  ===========================================%s\n' "$C_CYAN" "$C_RESET"
    printf '%s   %s%s\n' "$C_CYAN" "$(msg title)" "$C_RESET"
    printf '%s  ===========================================%s\n' "$C_CYAN" "$C_RESET"
    printf '\n'
    printf '   %s\n' "$(msg built_for)"
    printf '   %s\n' "$(msg built_for2)"
    printf '   %s%s%s\n' "$C_DIM" "$(msg not_affiliated)" "$C_RESET"
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
    # Accepts o/O for "oui" as well as y/Y, so a French prompt behaves.
    local answer
    answer="$(ask "$(msg q_yn "$1")" "$([ "$CBOOT_LANG" = 'fr' ] && printf 'o' || printf 'y')")"
    case "$answer" in
        [YyOo]*) return 0 ;;
        *)       return 1 ;;
    esac
}

# Which editor(s) to set up. Only asked when the chosen profile includes one.
choose_editor() {
    if [ -n "$CBOOT_EDITOR" ]; then
        printf '%s' "$CBOOT_EDITOR"
        return
    fi

    {
        printf '\n'
        printf '   %s\n\n' "$(msg q_editor)"
        printf '   %s\n' "$(msg q_editor_1)"
        printf '   %s\n' "$(msg q_editor_2)"
        printf '   %s\n' "$(msg q_editor_3)"
        printf '   %s\n\n' "$(msg q_editor_4)"
    } >&2

    case "$(ask "$(msg q_choose_1234)" '1')" in
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
            fail "$(msg e_windows "$(uname -s)")"
            printf '\n'
            printf '   %s\n\n' "$(msg e_win_use)"
            printf '     irm https://raw.githubusercontent.com/xelasleepi/cready/main/install.ps1 | iex\n\n'
            printf '   %s\n' "$(msg e_win_wsl)"
            printf '   %s\n' "$(msg e_win_wsl2)"
            printf '   %s\n\n' "$(msg e_win_wsl3)"
            exit 1
            ;;
        *)      die "$(msg e_os "$(uname -s)")" ;;
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
            fail "$(msg e_nobrew)"
            printf '\n'
            printf '   %s\n\n' "$(msg e_brew_get)"
            printf '     /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n\n'
            printf '   %s\n\n' "$(msg e_rerun)"
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
        else die "$(msg e_nopm)"
        fi
    fi

    # Root already? Then sudo is unnecessary and often absent in containers.
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=''
    elif command -v sudo >/dev/null 2>&1; then
        SUDO='sudo'
    else
        die "$(msg e_nosudo)"
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
        *)      die "$(msg e_pm "$PKG")" ;;
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

    note "$(msg installing "${pkgs[*]}")"
    if ! pm_install "${pkgs[@]}"; then
        die "$(msg tc_failed)"
    fi
    ok "$(msg tc_installed)"

    # Homebrew deliberately does not symlink an unversioned gcc, so `gcc` keeps
    # resolving to Apple's clang wrapper. Say so plainly instead of reporting a
    # GCC install that the student will never actually invoke.
    if [ "$PKG" = 'brew' ]; then
        local real_gcc
        real_gcc="$(ls "$(brew --prefix 2>/dev/null)/bin"/gcc-[0-9]* 2>/dev/null | sort -V | tail -1)"
        if [ -n "$real_gcc" ]; then
            warn "$(msg mac_clang)"
            note "$(msg mac_real "$real_gcc")"
            note "$(msg mac_use "$(basename "$real_gcc")" "$CBOOT_STD")"
            note "$(msg mac_fine)"
        fi
    fi

    # valgrind is standard in French university C courses for memory debugging,
    # but it is unavailable on some distros/architectures -- never fatal.
    if [ "$PKG" != 'brew' ]; then
        note "$(msg vg_installing)"
        if pm_install valgrind >/dev/null 2>&1; then
            ok "$(msg vg_ok)"
        else
            warn "$(msg vg_no)"
        fi
    fi
}

# --------------------------------------------------------------------------
# Visual Studio Code
# --------------------------------------------------------------------------

install_vscode() {
    if command -v code >/dev/null 2>&1; then
        ok "$(msg vscode_have "$(command -v code)")"
        install_cpp_extension
        return
    fi

    # In WSL you do NOT install the Linux GUI build. You install VS Code on
    # Windows and connect into the distro with the WSL remote extension --
    # that is the supported setup and avoids a broken GUI stack.
    if [ "$IS_WSL" = "1" ]; then
        warn "$(msg wsl_gui)"
        note "$(msg wsl_win)"
        note "$(msg wsl_ext)"
        note "$(msg wsl_code)"
        return
    fi

    case "$PKG" in
        apt)
            note "$(msg ms_repo)"
            pm_install wget gpg apt-transport-https >/dev/null 2>&1 || true

            # mktemp, not a fixed /tmp name: /tmp is world-writable, so a
            # predictable filename lets another local user pre-create a symlink
            # and redirect this write, or swap the key before it is installed
            # into the root-owned trusted keyring.
            local keyfile
            keyfile="$(mktemp)" || { warn "$(msg mktemp_fail)"; return; }

            # Every step is checked. A half-written key plus a live sources.list
            # entry would break `apt update` system-wide for the student, long
            # after this script has exited.
            if ! wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
                 | gpg --dearmor -o "$keyfile" 2>/dev/null || [ ! -s "$keyfile" ]; then
                rm -f "$keyfile"
                warn "$(msg key_fail)"
                note "$(msg key_untouched)"
                return
            fi

            if ! $SUDO install -D -o root -g root -m 644 \
                 "$keyfile" /etc/apt/keyrings/packages.microsoft.gpg; then
                rm -f "$keyfile"
                warn "$(msg key_inst_fail)"
                return
            fi
            rm -f "$keyfile"

            echo 'deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main' \
                | $SUDO tee /etc/apt/sources.list.d/vscode.list > /dev/null

            if ! pm_install code; then
                # Roll back rather than leaving a repo that breaks apt update.
                warn "$(msg repo_rollback)"
                $SUDO rm -f /etc/apt/sources.list.d/vscode.list \
                            /etc/apt/keyrings/packages.microsoft.gpg
                return
            fi
            ;;
        dnf|yum|zypper)
            note "$(msg ms_repo)"
            if ! $SUDO rpm --import https://packages.microsoft.com/keys/microsoft.asc; then
                warn "$(msg key_inst_fail)"
                return
            fi

            # zypper reads /etc/zypp/repos.d; only dnf/yum use /etc/yum.repos.d.
            local repofile='/etc/yum.repos.d/vscode.repo'
            [ "$PKG" = 'zypper' ] && repofile='/etc/zypp/repos.d/vscode.repo'

            printf '[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\nautorefresh=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n' \
                | $SUDO tee "$repofile" > /dev/null

            if ! pm_install code; then
                warn "$(msg repo_rollback)"
                $SUDO rm -f "$repofile"
                return
            fi
            ;;
        pacman)
            # VS Code proper is not in the Arch repos (only the OSS build).
            # AUR packages are community-maintained and run arbitrary build
            # scripts, so this is never done unattended.
            warn "$(msg aur_warn)"
            note "$(msg aur_note)"
            if command -v yay >/dev/null 2>&1; then
                confirm "$(msg aur_ask)" \
                    && { yay -S visual-studio-code-bin || warn "$(msg aur_fail)"; } \
                    || { note "$(msg skipped)"; return; }
            elif command -v paru >/dev/null 2>&1; then
                confirm "$(msg aur_ask)" \
                    && { paru -S visual-studio-code-bin || warn "$(msg aur_fail)"; } \
                    || { note "$(msg skipped)"; return; }
            else
                note "$(msg aur_helper)"
                note "$(msg aur_oss)"
                return
            fi
            ;;
        apk)
            warn 'VS Code is not packaged for Alpine - install it manually if needed.'
            return
            ;;
        brew)
            brew install --cask visual-studio-code || { warn "$(msg vscode_fail)"; return; }
            ;;
    esac

    if command -v code >/dev/null 2>&1; then
        ok "$(msg vscode_ok)"
        install_cpp_extension
    else
        warn "$(msg vscode_fail)"
    fi
}

install_cpp_extension() {
    note "$(msg ext_check)"
    if code --list-extensions 2>/dev/null | grep -qx 'ms-vscode.cpptools'; then
        ok "$(msg ext_have)"
    elif code --install-extension ms-vscode.cpptools --force >/dev/null 2>&1; then
        ok "$(msg ext_ok)"
    else
        warn "$(msg ext_fail)"
    fi
}

# --------------------------------------------------------------------------
# Kate
# --------------------------------------------------------------------------

install_kate() {
    if command -v kate >/dev/null 2>&1; then
        ok "$(msg kate_have "$(command -v kate)")"
        install_clangd
        return
    fi

    # Kate is a GUI application. Under WSL that needs WSLg (Windows 11 or
    # recent Windows 10); without it the install succeeds but nothing renders.
    if [ "$IS_WSL" = "1" ]; then
        warn "$(msg kate_wslg)"
        note "$(msg kate_wslg2)"
        if ! confirm "$(msg kate_wslg_ask)"; then
            note "$(msg kate_wslg_skip)"
            return
        fi
    fi

    note "$(msg kate_installing)"
    if [ "$PKG" = 'brew' ]; then
        brew install --cask kate || { warn "$(msg kate_fail)"; return; }
    elif ! pm_install kate; then
        warn "$(msg kate_fail)"
        return
    fi

    if command -v kate >/dev/null 2>&1; then
        ok "$(msg kate_ok)"
        install_clangd
    else
        warn "$(msg kate_nopath)"
    fi
}

# Kate has no built-in C parser; its LSP plugin drives clangd. Best-effort
# only, since Kate is still a usable editor without it.
install_clangd() {
    if command -v clangd >/dev/null 2>&1; then
        ok "$(msg clangd_have)"
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

    note "$(msg clangd_inst "$pkg")"
    if pm_install "$pkg" >/dev/null 2>&1 && command -v clangd >/dev/null 2>&1; then
        ok "$(msg clangd_ok)"
    else
        warn "$(msg clangd_no)"
    fi
}

# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------

verify_toolchain() {
    local want_cpp="$1" work
    CBOOT_WORK="$(mktemp -d)"
    work="$CBOOT_WORK"

    command -v gcc >/dev/null 2>&1 || die "$(msg v_nogcc)"

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
        die "$(msg v_cfail "$CBOOT_STD")"
    fi
    if ! "$work/verify" | grep -q 'TOOLCHAIN_OK 42'; then
        die "$(msg v_badout)"
    fi
    ok "$(msg v_cok "$CBOOT_STD")"
    ok "$(msg v_comments)"

    if [ "$want_cpp" = "1" ] && ! command -v g++ >/dev/null 2>&1; then
        warn "$(msg v_nogpp)"
        note "$(msg v_nogpp2)"
        cleanup_work
        return 0
    fi

    if [ "$want_cpp" = "1" ]; then
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
            ok "$(msg v_cppok)"
        else
            warn "$(msg v_cppfail)"
        fi
    fi

    cleanup_work
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
            note "$(msg sc_kept "$(basename "$target")")"
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

    ok "$(msg sc_ok "$dir")"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
    banner
    detect_platform

    local where="$DISTRO_NAME"
    [ "$IS_WSL" = "1" ] && where="$(msg wsl_suffix "$DISTRO_NAME")"
    printf '   %s\n' "$(msg detected "$where")"
    printf '   %s\n\n' "$(msg packages "$PKG")"

    # --- What is this for? ---
    local profile="$CBOOT_PROFILE"
    if [ -z "$profile" ]; then
        printf '   %s\n\n' "$(msg q_profile)"
        printf '   %s\n' "$(msg q_profile_1)"
        printf '   %s\n' "$(msg q_profile_2)"
        printf '   %s\n\n' "$(msg q_profile_3)"
        case "$(ask "$(msg q_choose_123)" '3')" in
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
        *)    die "$(msg e_profile "$profile")" ;;
    esac

    local editor='none' want_vscode=0 want_kate=0
    if [ "$want_editor" = "1" ]; then
        editor="$(choose_editor)"
        case "$editor" in
            vscode) want_vscode=1 ;;
            kate)   want_kate=1 ;;
            both)   want_vscode=1; want_kate=1 ;;
            none)   ;;
            *)      die "$(msg e_editor "$editor")" ;;
        esac
    fi

    local total=3
    [ "$want_vscode" = "1" ] && total=$((total + 1))
    [ "$want_kate" = "1" ]   && total=$((total + 1))
    [ -n "$CBOOT_SCAFFOLD_DIR" ] && total=$((total + 1))

    step 1 "$total" "$(msg s_check)"
    if command -v gcc >/dev/null 2>&1; then
        ok "$(msg found "$(command -v gcc)")"
        ok "$(gcc --version | head -1)"
        if ! confirm "$(msg q_reinstall)"; then
            note "$(msg keeping)"
            step 2 "$total" "$(msg s_skip)"
        else
            step 2 "$total" "$(msg s_install)"
            install_toolchain "$want_cpp"
        fi
    else
        note "$(msg no_gcc)"
        step 2 "$total" "$(msg s_install)"
        install_toolchain "$want_cpp"
    fi

    local next=3
    if [ "$want_vscode" = "1" ]; then
        step "$next" "$total" "$(msg s_vscode)"
        install_vscode
        next=$((next + 1))
    fi

    if [ "$want_kate" = "1" ]; then
        step "$next" "$total" "$(msg s_kate)"
        install_kate
        next=$((next + 1))
    fi

    if [ -n "$CBOOT_SCAFFOLD_DIR" ]; then
        step "$next" "$total" "$(msg s_scaffold)"
        create_scaffold "$CBOOT_SCAFFOLD_DIR"
        next=$((next + 1))
    fi

    step "$next" "$total" "$(msg s_verify)"
    verify_toolchain "$want_cpp"

    # --- Report ---
    printf '\n'
    printf '%s  ===========================================%s\n' "$C_GREEN" "$C_RESET"
    printf '%s   %s%s\n' "$C_GREEN" "$(msg done_title)" "$C_RESET"
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
    printf '%s   %s%s\n' "$C_CYAN" "$(msg compile_run)" "$C_RESET"
    printf '     gcc -std=%s -Wall hello.c -o hello\n' "$CBOOT_STD"
    printf '     ./hello\n'
    printf '\n'
}

main "$@"
