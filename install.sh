#!/usr/bin/env bash
#
# cready -- universal development environment bootstrapper (Linux, WSL, macOS)
# ---------------------------------------------------------------------------
# Written for students of Universite Sorbonne Paris Nord (Paris 13) who need an
# ANSI C toolchain for their coursework, but nothing here is specific to that
# university, and it is no longer limited to C.
#
# Installs, on request:
#   C / C++   gcc, g++, gdb, make, valgrind
#   C#        .NET SDK
#   Rust      rustup, cargo, rustc
#   Go        go
#   Python    python3, pip
#   Java      JDK (javac, java)
#
# Editors: Visual Studio Code, Kate, Vim.
#
# Every selected toolchain is verified by compiling and running a real
# program before the script reports success.
#
# Speaks French (default) and English. It asks which one you want before
# anything else; CBOOT_LANG=fr|en skips the question.
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
#     CBOOT_LANG=fr|en              skip the language question (default: fr)
#     CBOOT_TOOLCHAINS=cpp,rust     what to install (default: asks; "cpp" if piped)
#     CBOOT_EDITOR=vscode,vim|none  editors to install (default: asks)
#     CBOOT_ASSUME_YES=1            accept every default
#     CBOOT_STD=gnu89               standard used by the C verification compile
#     CBOOT_SCAFFOLD_DIR=~/c-lab    also create a starter C project
#
set -uo pipefail

CBOOT_STD="${CBOOT_STD:-gnu89}"
CBOOT_ASSUME_YES="${CBOOT_ASSUME_YES:-0}"
CBOOT_TOOLCHAINS="${CBOOT_TOOLCHAINS:-}"
CBOOT_EDITOR="${CBOOT_EDITOR:-}"
CBOOT_SCAFFOLD_DIR="${CBOOT_SCAFFOLD_DIR:-}"
CBOOT_LANG="${CBOOT_LANG:-}"
CBOOT_PROFILE="${CBOOT_PROFILE:-}"

# CBOOT_PROFILE predates multi-toolchain support. Keep it working rather than
# breaking anyone who copied an older command line.
if [ -n "$CBOOT_PROFILE" ] && [ -z "$CBOOT_TOOLCHAINS" ]; then
    case "$CBOOT_PROFILE" in
        c|cpp) CBOOT_TOOLCHAINS='cpp'; [ -z "$CBOOT_EDITOR" ] && CBOOT_EDITOR='none' ;;
        full)  CBOOT_TOOLCHAINS='cpp' ;;
    esac
fi

# French is the default, because that is who this was written for. English is a
# first-class option, not an afterthought: when the language was not pinned via
# the environment, the very first thing the script does is ask, bilingually.
CBOOT_LANG_EXPLICIT=0
if [ -n "$CBOOT_LANG" ]; then
    CBOOT_LANG_EXPLICIT=1
else
    CBOOT_LANG='fr'
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

# Every id the script accepts. Anything else is rejected rather than ignored,
# so a typo never silently installs nothing.
ALL_TOOLCHAINS='cpp dotnet rust go python java'
ALL_EDITORS='vscode kate vim'

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
    title)          en="Universal Development Environment Installer"
                    fr="Installateur universel d'environnement de développement" ;;
    built_for)      en="Built for Universite Sorbonne Paris Nord (Paris 13)"
                    fr="Conçu pour les étudiants de l'Université Sorbonne" ;;
    built_for2)     en="students, and for anyone else who needs a toolchain."
                    fr="Paris Nord (Paris 13), et pour tous les autres." ;;
    not_affiliated) en="Not affiliated with the university -- usable by anyone."
                    fr="Sans lien avec l'université -- utilisable par tous." ;;
    detected)       en="Detected: %s"
                    fr="Détecté : %s" ;;
    packages)       en="Packages: %s"
                    fr="Paquets : %s" ;;
    wsl_suffix)     en="%s (WSL -- Linux inside Windows)"
                    fr="%s (WSL -- Linux dans Windows)" ;;

    # -- toolchain names --------------------------------------------------
    tc_cpp)         en="C / C++       - gcc, g++, gdb, make, valgrind"
                    fr="C / C++       - gcc, g++, gdb, make, valgrind" ;;
    tc_dotnet)      en="C#            - .NET SDK"
                    fr="C#            - SDK .NET" ;;
    tc_rust)        en="Rust          - rustup, cargo, rustc"
                    fr="Rust          - rustup, cargo, rustc" ;;
    tc_go)          en="Go            - go compiler and tools"
                    fr="Go            - compilateur et outils Go" ;;
    tc_python)      en="Python        - python3 and pip"
                    fr="Python        - python3 et pip" ;;
    tc_java)        en="Java          - JDK (javac, java)"
                    fr="Java          - JDK (javac, java)" ;;

    # -- questions --------------------------------------------------------
    q_tc)           en="Which languages do you want?"
                    fr="Quels langages voulez-vous ?" ;;
    q_multi)        en="Pick one or several, separated by commas (e.g. 1,3)"
                    fr="Choisissez-en un ou plusieurs, séparés par des virgules (ex. 1,3)" ;;
    q_tc_ask)       en="Languages"
                    fr="Langages" ;;
    q_editor)       en="Which editors do you want?"
                    fr="Quels éditeurs voulez-vous ?" ;;
    ed_vscode)      en="Visual Studio Code  - full IDE, debugger, IntelliSense"
                    fr="Visual Studio Code  - IDE complet, débogueur, IntelliSense" ;;
    ed_kate)        en="Kate                - lightweight KDE editor"
                    fr="Kate                - éditeur KDE léger" ;;
    ed_vim)         en="Vim                 - terminal editor, always available"
                    fr="Vim                 - éditeur en terminal, toujours disponible" ;;
    ed_none)        en="0) None - I already have an editor"
                    fr="0) Aucun - j'ai déjà un éditeur" ;;
    q_editor_ask)   en="Editors"
                    fr="Éditeurs" ;;
    q_yn)           en="%s (y/n)"
                    fr="%s (o/n)" ;;
    q_reinstall)    en="%s is already installed. Reinstall/repair anyway?"
                    fr="%s est déjà installé. Réinstaller/réparer quand même ?" ;;
    e_badpick)      en="Unknown choice: %s"
                    fr="Choix inconnu : %s" ;;
    e_nopick)       en="Nothing selected - nothing to do."
                    fr="Aucune sélection - rien à faire." ;;

    # -- steps ------------------------------------------------------------
    s_install_tc)   en="Installing %s"
                    fr="Installation de %s" ;;
    s_editors)      en="Installing editors"
                    fr="Installation des éditeurs" ;;
    s_scaffold)     en="Creating the starter project"
                    fr="Création du projet de départ" ;;
    s_verify)       en="Verifying"
                    fr="Vérification" ;;

    # -- install ----------------------------------------------------------
    already)        en="%s already installed (%s)"
                    fr="%s est déjà installé (%s)" ;;
    installing)     en="Installing: %s"
                    fr="Installation : %s" ;;
    tc_ok)          en="%s installed"
                    fr="%s installé" ;;
    tc_failed)      en="%s installation failed - continuing with the rest"
                    fr="Échec de l'installation de %s - on continue" ;;
    tc_unsupported) en="%s is not packaged for this system - skipping"
                    fr="%s n'est pas disponible sur ce système - ignoré" ;;
    keeping)        en="Keeping the existing installation"
                    fr="Installation existante conservée" ;;
    vg_no)          en="valgrind unavailable on this system - skipping (not required)"
                    fr="valgrind indisponible sur ce système - ignoré (non requis)" ;;
    mac_clang)      en="On macOS, 'gcc' still runs Apple clang, not the GCC just installed."
                    fr="Sous macOS, 'gcc' lance toujours clang d'Apple, pas le GCC installé." ;;
    mac_real)       en="Real GCC is at: %s"
                    fr="Le vrai GCC se trouve ici : %s" ;;
    mac_fine)       en="For coursework, Apple clang accepts the same flags and is usually fine."
                    fr="Pour les TP, clang accepte les mêmes options et convient généralement." ;;
    rustup_note)    en="Installing via rustup, the official Rust installer"
                    fr="Installation via rustup, l'installateur officiel de Rust" ;;
    rustup_path)    en="Open a new terminal, or run: source \$HOME/.cargo/env"
                    fr="Ouvrez un nouveau terminal, ou lancez : source \$HOME/.cargo/env" ;;
    dotnet_script)  en="Distro package unavailable - using the official dotnet-install script"
                    fr="Paquet indisponible - utilisation du script officiel dotnet-install" ;;

    # -- editors ----------------------------------------------------------
    ms_repo)        en="Adding the Microsoft package repository"
                    fr="Ajout du dépôt de paquets Microsoft" ;;
    key_fail)       en="Could not download the Microsoft signing key - skipping VS Code"
                    fr="Impossible de télécharger la clé Microsoft - VS Code ignoré" ;;
    key_untouched)  en="Your apt configuration was left untouched."
                    fr="Votre configuration apt n'a pas été modifiée." ;;
    key_inst_fail)  en="Could not install the signing key - skipping VS Code"
                    fr="Impossible d'installer la clé de signature - VS Code ignoré" ;;
    repo_rollback)  en="Install failed - removing the repository entry again"
                    fr="Échec - suppression du dépôt ajouté" ;;
    mktemp_fail)    en="mktemp failed - skipping VS Code"
                    fr="Échec de mktemp - VS Code ignoré" ;;
    aur_warn)       en="VS Code on Arch comes from the AUR, which is community-maintained"
                    fr="Sur Arch, VS Code vient de l'AUR, maintenu par la communauté" ;;
    aur_note)       en="AUR packages run build scripts that nobody at Arch or Microsoft vetted."
                    fr="Les paquets AUR exécutent des scripts que ni Arch ni Microsoft n'ont validés." ;;
    aur_ask)        en="Install visual-studio-code-bin from the AUR?"
                    fr="Installer visual-studio-code-bin depuis l'AUR ?" ;;
    aur_helper)     en="No AUR helper found. Install yay or paru, then: yay -S visual-studio-code-bin"
                    fr="Aucun assistant AUR. Installez yay ou paru, puis : yay -S visual-studio-code-bin" ;;
    aur_oss)        en="Or use the open-source build instead: sudo pacman -S code"
                    fr="Ou utilisez la version open source : sudo pacman -S code" ;;
    skipped)        en="Skipped"
                    fr="Ignoré" ;;
    ext_check)      en="Ensuring the language extensions are present"
                    fr="Vérification des extensions de langage" ;;
    ext_ok)         en="Extension %s installed"
                    fr="Extension %s installée" ;;
    ext_have)       en="Extension %s already installed"
                    fr="Extension %s déjà installée" ;;
    ext_fail)       en="Could not install extension %s"
                    fr="Impossible d'installer l'extension %s" ;;
    wsl_gui)        en="Running under WSL - do not install the Linux GUI build here."
                    fr="Vous êtes sous WSL - n'installez pas la version graphique Linux ici." ;;
    wsl_win)        en="Install VS Code on WINDOWS instead:  https://code.visualstudio.com"
                    fr="Installez plutôt VS Code sous WINDOWS :  https://code.visualstudio.com" ;;
    wsl_ext)        en="Then add the extension:  ms-vscode-remote.remote-wsl"
                    fr="Puis ajoutez l'extension :  ms-vscode-remote.remote-wsl" ;;
    kate_wslg)      en="Kate is a GUI app and needs WSLg to display under WSL."
                    fr="Kate est une application graphique et nécessite WSLg sous WSL." ;;
    kate_wslg_ask)  en="Install Kate inside WSL anyway?"
                    fr="Installer Kate dans WSL malgré tout ?" ;;
    clangd_ok)      en="clangd installed - enable the LSP Client plugin in Kate"
                    fr="clangd installé - activez le plugin LSP Client dans Kate" ;;
    clangd_no)      en="clangd unavailable - Kate still works, just without completion"
                    fr="clangd indisponible - Kate fonctionne, mais sans complétion" ;;
    vimrc_ok)       en="Wrote a starter ~/.vimrc (syntax, indentation, line numbers)"
                    fr="Fichier ~/.vimrc de départ créé (syntaxe, indentation, numéros)" ;;
    vimrc_kept)     en="You already have a ~/.vimrc - left untouched"
                    fr="Vous avez déjà un ~/.vimrc - laissé intact" ;;

    # -- verification -----------------------------------------------------
    v_missing)      en="%s is not on PATH after installation"
                    fr="%s n'est pas dans le PATH après l'installation" ;;
    v_ok)           en="%s works"
                    fr="%s fonctionne" ;;
    v_fail)         en="%s failed its check"
                    fr="%s a échoué à sa vérification" ;;
    v_comments)     en="Both /* */ and // comment styles accepted (-std=%s)"
                    fr="Les commentaires /* */ et // sont acceptés (-std=%s)" ;;
    v_newshell)     en="%s needs a new terminal before it is on PATH"
                    fr="%s nécessite un nouveau terminal pour être dans le PATH" ;;

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
    e_pm)           en="Unknown package manager: %s"
                    fr="Gestionnaire de paquets inconnu : %s" ;;

    # -- size / disk ------------------------------------------------------
    plan_title)     en="About to install"
                    fr="Ce qui va être installé" ;;
    plan_total)     en="Estimated total"
                    fr="Total estimé" ;;
    plan_free)      en="Free space on %s"
                    fr="Espace libre sur %s" ;;
    plan_note)      en="Sizes are approximate and include dependencies."
                    fr="Tailles approximatives, dépendances comprises." ;;
    plan_already)   en="already installed, nothing to download"
                    fr="déjà installé, rien à télécharger" ;;
    q_proceed)      en="Proceed with the installation?"
                    fr="Lancer l'installation ?" ;;
    plan_cancel)    en="Cancelled - nothing was installed."
                    fr="Annulé - rien n'a été installé." ;;
    space_none)     en="Not enough free space: %s needed, %s available on %s."
                    fr="Espace insuffisant : %s nécessaires, %s disponibles sur %s." ;;
    space_low)      en="Space is tight: %s free, and installers need room to unpack."
                    fr="Espace limité : %s libres, et les installateurs ont besoin de place." ;;
    space_unknown)  en="Could not determine free disk space - continuing anyway"
                    fr="Impossible de déterminer l'espace disque - on continue" ;;

    # -- summary ----------------------------------------------------------
    done_title)     en="Installation complete"
                    fr="Installation terminée" ;;
    summary)        en="What you have now:"
                    fr="Ce dont vous disposez :" ;;
    reopen)         en="Open a NEW terminal before using the new tools."
                    fr="Ouvrez un NOUVEAU terminal avant d'utiliser les nouveaux outils." ;;
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
    printf '%s  =============================================%s\n' "$C_CYAN" "$C_RESET"
    printf '%s   cready -- %s%s\n' "$C_CYAN" "$(msg title)" "$C_RESET"
    printf '%s  =============================================%s\n' "$C_CYAN" "$C_RESET"
    printf '\n'
    printf '   %s\n' "$(msg built_for)"
    printf '   %s\n' "$(msg built_for2)"
    printf '   %s%s%s\n' "$C_DIM" "$(msg not_affiliated)" "$C_RESET"
    printf '\n'
    # Always shown, in both languages, whichever one is active.
    printf '   %sFrancais / English  --  CBOOT_LANG=fr | CBOOT_LANG=en%s\n' "$C_CYAN" "$C_RESET"
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

# confirm <prompt> [default]
# Accepts o/O for "oui" as well as y/Y, so a French prompt behaves.
confirm() {
    local want_no=0 default answer
    [ "${2:-yes}" = 'no' ] && want_no=1
    if [ "$want_no" = 1 ]; then
        default="$([ "$CBOOT_LANG" = 'fr' ] && printf 'n' || printf 'n')"
    else
        default="$([ "$CBOOT_LANG" = 'fr' ] && printf 'o' || printf 'y')"
    fi
    answer="$(ask "$(msg q_yn "$1")" "$default")"
    case "$answer" in
        [YyOo]*) return 0 ;;
        *)       return 1 ;;
    esac
}

# Asked before anything else, and printed in both languages, so an English
# speaker never has to guess. Skipped entirely when CBOOT_LANG was set.
choose_language() {
    if ! can_prompt; then
        printf 'fr'
        return
    fi
    {
        printf '\n'
        printf '   +---------------------------------------+\n'
        printf '   |   Langue  /  Language                 |\n'
        printf '   +---------------------------------------+\n\n'
        printf '     1) Francais   (par defaut / default)\n'
        printf '     2) English\n\n'
    } >&2
    case "$(ask 'Choisissez / Choose' '1')" in
        2) printf 'en' ;;
        *) printf 'fr' ;;
    esac
}

# Turns "1,3" or "1 3" into a space-separated list of ids drawn from $2.
# Prints nothing and returns 1 when a number is out of range.
map_choice() {
    local input="$1" ids="$2" out='' n id i
    input="$(printf '%s' "$input" | tr ',' ' ')"
    for n in $input; do
        case "$n" in
            ''|*[!0-9]*) printf '%s' "$n"; return 1 ;;
        esac
        i=1
        id=''
        for candidate in $ids; do
            if [ "$i" -eq "$n" ]; then id="$candidate"; break; fi
            i=$((i + 1))
        done
        [ -z "$id" ] && { printf '%s' "$n"; return 1; }
        case " $out " in
            *" $id "*) ;;            # already picked, ignore duplicates
            *) out="$out $id" ;;
        esac
    done
    printf '%s' "${out# }"
    return 0
}

choose_toolchains() {
    if [ -n "$CBOOT_TOOLCHAINS" ]; then
        printf '%s' "$(printf '%s' "$CBOOT_TOOLCHAINS" | tr ',' ' ')"
        return
    fi
    if ! can_prompt; then
        printf 'cpp'
        return
    fi

    {
        printf '\n'
        printf '   %s\n' "$(msg q_tc)"
        printf '   %s%s%s\n\n' "$C_DIM" "$(msg q_multi)" "$C_RESET"
        printf '     1) %-46s ~ %s\n'   "$(msg tc_cpp)"    "$(human_mb "$(tc_size cpp)")"
        printf '     2) %-46s ~ %s\n'   "$(msg tc_dotnet)" "$(human_mb "$(tc_size dotnet)")"
        printf '     3) %-46s ~ %s\n'   "$(msg tc_rust)"   "$(human_mb "$(tc_size rust)")"
        printf '     4) %-46s ~ %s\n'   "$(msg tc_go)"     "$(human_mb "$(tc_size go)")"
        printf '     5) %-46s ~ %s\n'   "$(msg tc_python)" "$(human_mb "$(tc_size python)")"
        printf '     6) %-46s ~ %s\n\n' "$(msg tc_java)"   "$(human_mb "$(tc_size java)")"
    } >&2

    local picked bad
    while : ; do
        picked="$(ask "$(msg q_tc_ask)" '1')"
        if bad="$(map_choice "$picked" "$ALL_TOOLCHAINS")"; then
            printf '%s' "$bad"
            return
        fi
        printf '      %s\n' "$(msg e_badpick "$bad")" >&2
        can_prompt || { printf 'cpp'; return; }
    done
}

choose_editors() {
    if [ -n "$CBOOT_EDITOR" ]; then
        case "$CBOOT_EDITOR" in
            none) printf '' ;;
            *)    printf '%s' "$(printf '%s' "$CBOOT_EDITOR" | tr ',' ' ')" ;;
        esac
        return
    fi
    if ! can_prompt; then
        printf ''
        return
    fi

    {
        printf '\n'
        printf '   %s\n' "$(msg q_editor)"
        printf '   %s%s%s\n\n' "$C_DIM" "$(msg q_multi)" "$C_RESET"
        printf '     1) %-46s ~ %s\n' "$(msg ed_vscode)" "$(human_mb "$(ed_size vscode)")"
        printf '     2) %-46s ~ %s\n' "$(msg ed_kate)"   "$(human_mb "$(ed_size kate)")"
        printf '     3) %-46s ~ %s\n' "$(msg ed_vim)"    "$(human_mb "$(ed_size vim)")"
        printf '     %s\n\n' "$(msg ed_none)"
    } >&2

    local picked bad
    while : ; do
        picked="$(ask "$(msg q_editor_ask)" '1')"
        case "$picked" in
            0) printf ''; return ;;
        esac
        if bad="$(map_choice "$picked" "$ALL_EDITORS")"; then
            printf '%s' "$bad"
            return
        fi
        printf '      %s\n' "$(msg e_badpick "$bad")" >&2
        can_prompt || { printf ''; return; }
    done
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

# --------------------------------------------------------------------------
# Toolchain registry
#
# Four small functions keyed by toolchain id keep everything about a language
# in one place: its display name, its packages, how to detect it, and how to
# prove it works.
# --------------------------------------------------------------------------

tc_label() {
    case "$1" in
        cpp)    printf 'C / C++' ;;
        dotnet) printf 'C# (.NET)' ;;
        rust)   printf 'Rust' ;;
        go)     printf 'Go' ;;
        python) printf 'Python' ;;
        java)   printf 'Java' ;;
        *)      printf '%s' "$1" ;;
    esac
}

# The command that proves a toolchain is present.
tc_probe() {
    case "$1" in
        cpp)    printf 'gcc' ;;
        dotnet) printf 'dotnet' ;;
        rust)   printf 'rustc' ;;
        go)     printf 'go' ;;
        python) printf 'python3' ;;
        java)   printf 'javac' ;;
    esac
}

# Packages for the active package manager. Empty output means "no package
# mapping", which the caller reports as unsupported rather than failing.
tc_packages() {
    case "$1:$PKG" in
        cpp:apt)        printf 'build-essential gdb' ;;
        cpp:dnf|cpp:yum) printf 'gcc gcc-c++ make gdb glibc-devel' ;;
        cpp:pacman)     printf 'base-devel gdb' ;;
        cpp:zypper)     printf 'gcc gcc-c++ make gdb glibc-devel' ;;
        cpp:apk)        printf 'build-base gdb' ;;
        cpp:brew)       printf 'gcc make' ;;

        dotnet:apt)     printf 'dotnet-sdk-8.0' ;;
        dotnet:dnf|dotnet:yum) printf 'dotnet-sdk-8.0' ;;
        dotnet:pacman)  printf 'dotnet-sdk' ;;
        dotnet:zypper)  printf 'dotnet-sdk-8.0' ;;
        dotnet:apk)     printf 'dotnet8-sdk' ;;
        dotnet:brew)    printf '' ;;   # cask, handled specially

        go:apt)         printf 'golang-go' ;;
        go:dnf|go:yum)  printf 'golang' ;;
        go:pacman)      printf 'go' ;;
        go:zypper)      printf 'go' ;;
        go:apk)         printf 'go' ;;
        go:brew)        printf 'go' ;;

        python:apt)     printf 'python3 python3-pip python3-venv' ;;
        python:dnf|python:yum) printf 'python3 python3-pip' ;;
        python:pacman)  printf 'python python-pip' ;;
        python:zypper)  printf 'python3 python3-pip' ;;
        python:apk)     printf 'python3 py3-pip' ;;
        python:brew)    printf 'python' ;;

        java:apt)       printf 'default-jdk' ;;
        java:dnf|java:yum) printf 'java-latest-openjdk-devel' ;;
        java:pacman)    printf 'jdk-openjdk' ;;
        java:zypper)    printf 'java-17-openjdk-devel' ;;
        java:apk)       printf 'openjdk17' ;;
        java:brew)      printf 'openjdk' ;;

        # rust intentionally has no distro packages: rustup is the supported
        # route and is what every Rust tutorial assumes.
        rust:*)         printf '' ;;
        *)              printf '' ;;
    esac
}

# Approximate installed size in MB, dependencies included. Deliberately on the
# generous side: warning about space you turned out not to need is a much
# smaller problem than running out halfway through a 1 GB download.
tc_size() {
    case "$1" in
        cpp)    printf '450' ;;
        dotnet) printf '850' ;;
        rust)   printf '1300' ;;
        go)     printf '550' ;;
        python) printf '200' ;;
        java)   printf '400' ;;
        *)      printf '100' ;;
    esac
}

ed_label() {
    case "$1" in
        vscode) printf 'Visual Studio Code' ;;
        kate)   printf 'Kate' ;;
        vim)    printf 'Vim' ;;
        *)      printf '%s' "$1" ;;
    esac
}

ed_size() {
    case "$1" in
        vscode) printf '400' ;;
        kate)   printf '120' ;;
        vim)    printf '50' ;;
        *)      printf '50' ;;
    esac
}

ed_probe() {
    case "$1" in
        vscode) printf 'code' ;;
        kate)   printf 'kate' ;;
        vim)    printf 'vim' ;;
    esac
}

human_mb() {
    local mb="$1"
    if [ "$mb" -ge 1024 ]; then
        printf '%d.%d GB' "$((mb / 1024))" "$(( (mb % 1024) * 10 / 1024 ))"
    else
        printf '%d MB' "$mb"
    fi
}

# Available space in MB on the filesystem holding $1. Prints nothing when df
# is unavailable or fails, which callers treat as "unknown" rather than zero.
free_mb() {
    df -Pk "$1" 2>/dev/null | awk 'NR==2 { print int($4/1024) }'
}

install_toolchain() {
    local id="$1" label packages probe
    label="$(tc_label "$id")"
    probe="$(tc_probe "$id")"

    if command -v "$probe" >/dev/null 2>&1; then
        ok "$(msg already "$label" "$(command -v "$probe")")"
        if ! confirm "$(msg q_reinstall "$label")" no; then
            note "$(msg keeping)"
            return 0
        fi
    fi

    case "$id" in
        rust)
            note "$(msg rustup_note)"
            if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
                 | sh -s -- -y --no-modify-path >/dev/null 2>&1; then
                warn "$(msg tc_failed "$label")"
                return 1
            fi
            # rustup installs into ~/.cargo/bin, which is not on PATH until a
            # new shell reads the profile it just edited.
            [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
            export PATH="$HOME/.cargo/bin:$PATH"
            ok "$(msg tc_ok "$label")"
            note "$(msg rustup_path)"
            return 0
            ;;
        dotnet)
            if [ "$PKG" = 'brew' ]; then
                brew install --cask dotnet-sdk || { warn "$(msg tc_failed "$label")"; return 1; }
                ok "$(msg tc_ok "$label")"
                return 0
            fi
            packages="$(tc_packages "$id")"
            if [ -n "$packages" ] && pm_install $packages; then
                ok "$(msg tc_ok "$label")"
                return 0
            fi
            # Distro packaging for .NET is inconsistent across versions, so
            # fall back to Microsoft's own installer rather than giving up.
            note "$(msg dotnet_script)"
            if curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
               && bash /tmp/dotnet-install.sh --channel LTS --install-dir "$HOME/.dotnet" >/dev/null 2>&1; then
                rm -f /tmp/dotnet-install.sh
                export PATH="$HOME/.dotnet:$PATH"
                ok "$(msg tc_ok "$label")"
                note "$(msg v_newshell "$label")"
                return 0
            fi
            rm -f /tmp/dotnet-install.sh
            warn "$(msg tc_failed "$label")"
            return 1
            ;;
    esac

    packages="$(tc_packages "$id")"
    if [ -z "$packages" ]; then
        warn "$(msg tc_unsupported "$label")"
        return 1
    fi

    note "$(msg installing "$packages")"
    if ! pm_install $packages; then
        warn "$(msg tc_failed "$label")"
        return 1
    fi
    ok "$(msg tc_ok "$label")"

    if [ "$id" = 'cpp' ]; then
        # valgrind is standard in French university C courses, but it is
        # unavailable on some distros and architectures -- never fatal.
        if [ "$PKG" != 'brew' ] && ! command -v valgrind >/dev/null 2>&1; then
            pm_install valgrind >/dev/null 2>&1 || warn "$(msg vg_no)"
        fi
        # Homebrew deliberately does not symlink an unversioned gcc, so `gcc`
        # keeps resolving to Apple's clang wrapper. Say so plainly.
        if [ "$PKG" = 'brew' ]; then
            local real_gcc
            real_gcc="$(ls "$(brew --prefix 2>/dev/null)/bin"/gcc-[0-9]* 2>/dev/null | sort -V | tail -1)"
            if [ -n "$real_gcc" ]; then
                warn "$(msg mac_clang)"
                note "$(msg mac_real "$real_gcc")"
                note "$(msg mac_fine)"
            fi
        fi
    fi
    return 0
}

# --------------------------------------------------------------------------
# Verification
#
# Each toolchain compiles and runs a real program. Nothing is reported as
# working on the strength of a version string alone, except .NET, whose
# project scaffolding is too slow to justify in an installer.
# --------------------------------------------------------------------------

verify_toolchain() {
    local id="$1" label probe
    label="$(tc_label "$id")"
    probe="$(tc_probe "$id")"

    if ! command -v "$probe" >/dev/null 2>&1; then
        warn "$(msg v_missing "$label")"
        return 1
    fi

    CBOOT_WORK="$(mktemp -d)"
    local w="$CBOOT_WORK" rc=0

    case "$id" in
        cpp)
            # Mixes ANSI block comments with // line comments, so a pass proves
            # the configured standard accepts both styles.
            cat > "$w/v.c" <<'EOF'
#include <stdio.h>
/* ANSI C style block comment */
int main(void)
{
    int value = 42;   // line comment - rejected by strict c89
    printf("OK %d\n", value);
    return 0;
}
EOF
            if gcc -std="$CBOOT_STD" -Wall -Wextra "$w/v.c" -o "$w/v" 2>/dev/null \
               && "$w/v" | grep -q 'OK 42'; then
                ok "$(msg v_ok "C")"
                ok "$(msg v_comments "$CBOOT_STD")"
            else
                warn "$(msg v_fail "C")"; rc=1
            fi

            if command -v g++ >/dev/null 2>&1; then
                cat > "$w/v.cpp" <<'EOF'
#include <iostream>
#include <vector>
int main() { std::vector<int> v{1,2,3}; for (int i : v) std::cout << i; std::cout << " OK\n"; }
EOF
                if g++ -std=c++17 "$w/v.cpp" -o "$w/vpp" 2>/dev/null && "$w/vpp" | grep -q 'OK'; then
                    ok "$(msg v_ok "C++")"
                else
                    warn "$(msg v_fail "C++")"; rc=1
                fi
            fi
            ;;
        rust)
            printf 'fn main() { println!("OK"); }\n' > "$w/v.rs"
            if (cd "$w" && rustc v.rs -o v 2>/dev/null) && "$w/v" | grep -q 'OK'; then
                ok "$(msg v_ok "$label")"
            else
                warn "$(msg v_fail "$label")"; rc=1
            fi
            ;;
        go)
            printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("OK") }\n' > "$w/v.go"
            if (cd "$w" && GOCACHE="$w/.cache" go run v.go 2>/dev/null | grep -q 'OK'); then
                ok "$(msg v_ok "$label")"
            else
                warn "$(msg v_fail "$label")"; rc=1
            fi
            ;;
        python)
            if python3 -c 'print("OK")' 2>/dev/null | grep -q 'OK'; then
                ok "$(msg v_ok "$label")"
            else
                warn "$(msg v_fail "$label")"; rc=1
            fi
            ;;
        java)
            cat > "$w/Hello.java" <<'EOF'
public class Hello { public static void main(String[] a) { System.out.println("OK"); } }
EOF
            if (cd "$w" && javac Hello.java 2>/dev/null && java Hello 2>/dev/null | grep -q 'OK'); then
                ok "$(msg v_ok "$label")"
            else
                warn "$(msg v_fail "$label")"; rc=1
            fi
            ;;
        dotnet)
            # `dotnet new` + build costs tens of seconds on first run, so this
            # checks the SDK is registered rather than building a project.
            if dotnet --list-sdks 2>/dev/null | grep -q '.'; then
                ok "$(msg v_ok "$label")"
            else
                warn "$(msg v_fail "$label")"; rc=1
            fi
            ;;
    esac

    cleanup_work
    return $rc
}

# --------------------------------------------------------------------------
# Editors
# --------------------------------------------------------------------------

install_vscode() {
    if command -v code >/dev/null 2>&1; then
        ok "$(msg already "VS Code" "$(command -v code)")"
        install_vscode_extensions
        return
    fi

    # In WSL you do NOT install the Linux GUI build. You install VS Code on
    # Windows and connect into the distro with the WSL remote extension --
    # that is the supported setup and avoids a broken GUI stack.
    if [ "$IS_WSL" = "1" ]; then
        warn "$(msg wsl_gui)"
        note "$(msg wsl_win)"
        note "$(msg wsl_ext)"
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
            # entry would break `apt update` system-wide, long after this exits.
            if ! wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
                 | gpg --dearmor -o "$keyfile" 2>/dev/null || [ ! -s "$keyfile" ]; then
                rm -f "$keyfile"; warn "$(msg key_fail)"; note "$(msg key_untouched)"; return
            fi
            if ! $SUDO install -D -o root -g root -m 644 \
                 "$keyfile" /etc/apt/keyrings/packages.microsoft.gpg; then
                rm -f "$keyfile"; warn "$(msg key_inst_fail)"; return
            fi
            rm -f "$keyfile"

            echo 'deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main' \
                | $SUDO tee /etc/apt/sources.list.d/vscode.list > /dev/null

            if ! pm_install code; then
                warn "$(msg repo_rollback)"
                $SUDO rm -f /etc/apt/sources.list.d/vscode.list \
                            /etc/apt/keyrings/packages.microsoft.gpg
                return
            fi
            ;;
        dnf|yum|zypper)
            note "$(msg ms_repo)"
            $SUDO rpm --import https://packages.microsoft.com/keys/microsoft.asc \
                || { warn "$(msg key_inst_fail)"; return; }
            # zypper reads /etc/zypp/repos.d; only dnf/yum use /etc/yum.repos.d.
            local repofile='/etc/yum.repos.d/vscode.repo'
            [ "$PKG" = 'zypper' ] && repofile='/etc/zypp/repos.d/vscode.repo'
            printf '[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\nautorefresh=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n' \
                | $SUDO tee "$repofile" > /dev/null
            if ! pm_install code; then
                warn "$(msg repo_rollback)"; $SUDO rm -f "$repofile"; return
            fi
            ;;
        pacman)
            # VS Code proper is not in the Arch repos (only the OSS build), and
            # AUR packages run arbitrary build scripts, so never unattended.
            warn "$(msg aur_warn)"
            note "$(msg aur_note)"
            if command -v yay >/dev/null 2>&1; then
                confirm "$(msg aur_ask)" && yay -S visual-studio-code-bin || { note "$(msg skipped)"; return; }
            elif command -v paru >/dev/null 2>&1; then
                confirm "$(msg aur_ask)" && paru -S visual-studio-code-bin || { note "$(msg skipped)"; return; }
            else
                note "$(msg aur_helper)"; note "$(msg aur_oss)"; return
            fi
            ;;
        apk)
            warn "$(msg tc_unsupported 'VS Code')"; return ;;
        brew)
            brew install --cask visual-studio-code || { warn "$(msg tc_failed 'VS Code')"; return; }
            ;;
    esac

    if command -v code >/dev/null 2>&1; then
        ok "$(msg tc_ok 'VS Code')"
        install_vscode_extensions
    else
        warn "$(msg tc_failed 'VS Code')"
    fi
}

# Extensions follow the languages that were actually installed, so a Python-only
# setup does not drag in the C/C++ toolset and vice versa.
install_vscode_extensions() {
    local ext id
    note "$(msg ext_check)"
    for id in $SELECTED_TOOLCHAINS; do
        case "$id" in
            cpp)    ext='ms-vscode.cpptools' ;;
            dotnet) ext='ms-dotnettools.csharp' ;;
            rust)   ext='rust-lang.rust-analyzer' ;;
            go)     ext='golang.go' ;;
            python) ext='ms-python.python' ;;
            java)   ext='redhat.java' ;;
            *)      continue ;;
        esac
        if code --list-extensions 2>/dev/null | grep -qx "$ext"; then
            ok "$(msg ext_have "$ext")"
        elif code --install-extension "$ext" --force >/dev/null 2>&1; then
            ok "$(msg ext_ok "$ext")"
        else
            warn "$(msg ext_fail "$ext")"
        fi
    done
}

install_kate() {
    if command -v kate >/dev/null 2>&1; then
        ok "$(msg already 'Kate' "$(command -v kate)")"
        install_clangd
        return
    fi

    # Kate is a GUI application. Under WSL that needs WSLg (Windows 11 or
    # recent Windows 10); without it the install succeeds but nothing renders.
    if [ "$IS_WSL" = "1" ]; then
        warn "$(msg kate_wslg)"
        confirm "$(msg kate_wslg_ask)" || { note "$(msg skipped)"; return; }
    fi

    if [ "$PKG" = 'brew' ]; then
        brew install --cask kate || { warn "$(msg tc_failed 'Kate')"; return; }
    elif ! pm_install kate; then
        warn "$(msg tc_failed 'Kate')"; return
    fi

    if command -v kate >/dev/null 2>&1; then
        ok "$(msg tc_ok 'Kate')"
        install_clangd
    else
        warn "$(msg tc_failed 'Kate')"
    fi
}

# Kate has no built-in C parser; its LSP plugin drives clangd. Best-effort
# only, and only worth installing when a C/C++ toolchain was selected.
install_clangd() {
    case " $SELECTED_TOOLCHAINS " in *" cpp "*) ;; *) return ;; esac
    command -v clangd >/dev/null 2>&1 && { ok "$(msg already 'clangd' "$(command -v clangd)")"; return; }

    local pkg='clangd'
    case "$PKG" in
        dnf|yum)  pkg='clang-tools-extra' ;;
        pacman)   pkg='clang' ;;
        zypper)   pkg='clang-tools' ;;
        apk)      pkg='clang-extra-tools' ;;
        brew)     pkg='llvm' ;;
    esac
    if pm_install "$pkg" >/dev/null 2>&1 && command -v clangd >/dev/null 2>&1; then
        ok "$(msg clangd_ok)"
    else
        warn "$(msg clangd_no)"
    fi
}

install_vim() {
    if command -v vim >/dev/null 2>&1; then
        ok "$(msg already 'Vim' "$(command -v vim)")"
    else
        if [ "$PKG" = 'brew' ]; then
            brew install vim || { warn "$(msg tc_failed 'Vim')"; return; }
        elif ! pm_install vim; then
            warn "$(msg tc_failed 'Vim')"; return
        fi
        command -v vim >/dev/null 2>&1 && ok "$(msg tc_ok 'Vim')" || { warn "$(msg tc_failed 'Vim')"; return; }
    fi
    write_vimrc
}

# A stock vim has no syntax highlighting and 8-wide tabs, which is a rough
# first impression. Only ever written when the user has no vimrc at all.
write_vimrc() {
    local rc="$HOME/.vimrc"
    if [ -e "$rc" ]; then
        note "$(msg vimrc_kept)"
        return
    fi
    cat > "$rc" <<'VIMRC'
" Starter configuration written by cready. Edit freely.
syntax on
filetype plugin indent on

set number
set tabstop=4
set shiftwidth=4
set expandtab
set autoindent
set smartindent

set incsearch
set hlsearch
set ignorecase
set smartcase

set ruler
set showcmd
set wildmenu
set backspace=indent,eol,start
set encoding=utf-8

" F5 builds and runs the current C file with the same flags cready verifies.
autocmd FileType c nnoremap <F5> :w<CR>:!gcc -std=gnu89 -Wall -Wextra % -o %:r && ./%:r<CR>
VIMRC
    ok "$(msg vimrc_ok)"
}

install_editor() {
    case "$1" in
        vscode) install_vscode ;;
        kate)   install_kate ;;
        vim)    install_vim ;;
    esac
}

# --------------------------------------------------------------------------
# Starter project (C only -- the course this was written for)
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
        cat > "$dir/main.c" <<'EOF'
#include <stdio.h>

/* ANSI C with // comments enabled via -std=gnu89 */
int main(void)
{
    printf("Hello, C!\n");   // press F5 to build and debug
    return 0;
}
EOF
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

SELECTED_TOOLCHAINS=''
SELECTED_EDITORS=''

# Prints what is about to happen, what it costs, and what the disk has, then
# asks for confirmation. Anything already installed is counted as 0 MB and
# labelled, so the number reflects what will actually be downloaded.
show_plan_and_confirm() {
    local total=0 id sz probe target free need

    printf '\n   %s\n\n' "$(msg plan_title)"

    for id in $SELECTED_TOOLCHAINS; do
        probe="$(tc_probe "$id")"
        if command -v "$probe" >/dev/null 2>&1; then
            printf '     %-22s %s%s%s\n' "$(tc_label "$id")" "$C_DIM" "$(msg plan_already)" "$C_RESET"
        else
            sz="$(tc_size "$id")"; total=$((total + sz))
            printf '     %-22s ~ %s\n' "$(tc_label "$id")" "$(human_mb "$sz")"
        fi
    done

    for id in $SELECTED_EDITORS; do
        probe="$(ed_probe "$id")"
        if command -v "$probe" >/dev/null 2>&1; then
            printf '     %-22s %s%s%s\n' "$(ed_label "$id")" "$C_DIM" "$(msg plan_already)" "$C_RESET"
        else
            sz="$(ed_size "$id")"; total=$((total + sz))
            printf '     %-22s ~ %s\n' "$(ed_label "$id")" "$(human_mb "$sz")"
        fi
    done

    printf '     %s\n' '---------------------------------------------'
    printf '     %-22s ~ %s\n' "$(msg plan_total)" "$(human_mb "$total")"

    # Packages land under /, rustup and the dotnet fallback under $HOME. When
    # those are separate filesystems the smaller one is what constrains us.
    target='/'
    free="$(free_mb '/')"
    local home_free
    home_free="$(free_mb "$HOME")"
    if [ -n "$home_free" ] && [ -n "$free" ] && [ "$home_free" -lt "$free" ]; then
        target="$HOME"; free="$home_free"
    fi

    if [ -z "$free" ]; then
        printf '\n'
        warn "$(msg space_unknown)"
    else
        printf '     %-22s   %s\n' "$(msg plan_free "$target")" "$(human_mb "$free")"
        printf '\n   %s%s%s\n' "$C_DIM" "$(msg plan_note)" "$C_RESET"

        # Installers unpack before they clean up, so headroom beyond the final
        # footprint is genuinely needed, not padding.
        need=$(( total * 5 / 4 + 500 ))
        if [ "$total" -gt 0 ] && [ "$free" -lt "$total" ]; then
            die "$(msg space_none "$(human_mb "$need")" "$(human_mb "$free")" "$target")"
        fi
        if [ "$total" -gt 0 ] && [ "$free" -lt "$need" ]; then
            warn "$(msg space_low "$(human_mb "$free")")"
        fi
    fi

    printf '\n'
    if [ "$total" -eq 0 ]; then
        return 0
    fi
    if ! confirm "$(msg q_proceed)"; then
        printf '\n'
        note "$(msg plan_cancel)"
        printf '\n'
        exit 0
    fi
}

main() {
    # Before the banner, because the banner itself is localized.
    if [ "$CBOOT_LANG_EXPLICIT" = "0" ]; then
        CBOOT_LANG="$(choose_language)"
    fi

    banner
    detect_platform

    local where="$DISTRO_NAME"
    [ "$IS_WSL" = "1" ] && where="$(msg wsl_suffix "$DISTRO_NAME")"
    printf '   %s\n' "$(msg detected "$where")"
    printf '   %s\n' "$(msg packages "$PKG")"

    SELECTED_TOOLCHAINS="$(choose_toolchains)"
    SELECTED_EDITORS="$(choose_editors)"

    # Validate ids that came from the environment rather than the menu.
    local id
    for id in $SELECTED_TOOLCHAINS; do
        case " $ALL_TOOLCHAINS " in *" $id "*) ;; *) die "$(msg e_badpick "$id")" ;; esac
    done
    for id in $SELECTED_EDITORS; do
        case " $ALL_EDITORS " in *" $id "*) ;; *) die "$(msg e_badpick "$id")" ;; esac
    done
    [ -z "$SELECTED_TOOLCHAINS" ] && [ -z "$SELECTED_EDITORS" ] && die "$(msg e_nopick)"

    show_plan_and_confirm

    local total=0
    for id in $SELECTED_TOOLCHAINS; do total=$((total + 1)); done
    [ -n "$SELECTED_EDITORS" ] && total=$((total + 1))
    [ -n "$CBOOT_SCAFFOLD_DIR" ] && total=$((total + 1))
    total=$((total + 1))   # verification step
    local n=1

    for id in $SELECTED_TOOLCHAINS; do
        step "$n" "$total" "$(msg s_install_tc "$(tc_label "$id")")"
        install_toolchain "$id"
        n=$((n + 1))
    done

    if [ -n "$SELECTED_EDITORS" ]; then
        step "$n" "$total" "$(msg s_editors)"
        for id in $SELECTED_EDITORS; do install_editor "$id"; done
        n=$((n + 1))
    fi

    if [ -n "$CBOOT_SCAFFOLD_DIR" ]; then
        step "$n" "$total" "$(msg s_scaffold)"
        create_scaffold "$CBOOT_SCAFFOLD_DIR"
        n=$((n + 1))
    fi

    step "$n" "$total" "$(msg s_verify)"
    for id in $SELECTED_TOOLCHAINS; do verify_toolchain "$id"; done

    # --- Report ---
    printf '\n'
    printf '%s  =============================================%s\n' "$C_GREEN" "$C_RESET"
    printf '%s   %s%s\n' "$C_GREEN" "$(msg done_title)" "$C_RESET"
    printf '%s  =============================================%s\n' "$C_GREEN" "$C_RESET"
    printf '\n'
    printf '   %s\n\n' "$(msg summary)"
    for tool in gcc g++ gdb make valgrind clangd dotnet rustc cargo go python3 pip3 javac java code kate vim; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf '   %-10s %s\n' "$tool" "$(command -v "$tool")"
        fi
    done
    printf '\n'
    printf '%s   %s%s\n' "$C_YELLOW" "$(msg reopen)" "$C_RESET"
    printf '\n'
}

main "$@"
