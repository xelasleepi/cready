#Requires -Version 5.1
<#
    cready -- universal development environment bootstrapper for Windows
    --------------------------------------------------------------------
    Written for students of Universite Sorbonne Paris Nord (Paris 13) who need
    an ANSI C toolchain for their coursework, but nothing here is specific to
    that university, and it is no longer limited to C.

    Installs, on request:
      C / C++   MSYS2 + MinGW-w64 UCRT64 (gcc, g++, gdb, mingw32-make)
      C#        .NET SDK
      Rust      rustup, cargo, rustc
      Go        go
      Python    python3, pip
      Java      Microsoft OpenJDK (javac, java)

    Editors: Visual Studio Code, Kate, Vim.

    Every selected toolchain is verified by compiling and running a real
    program before the script reports success.

    Speaks French (default) and English. It asks which one you want before
    anything else; CBOOT_LANG=fr|en skips the question.

    This file is deliberately self-contained and exceeds the usual size limit
    for a source file. It has to be: it is fetched and executed in one piece by
    `irm | iex`, so it cannot dot-source helpers that do not exist on the
    machine yet. Sections are separated by banner comments instead.

    Usage (remote):
        irm https://raw.githubusercontent.com/xelasleepi/cready/main/install.ps1 | iex

    Usage (local):
        powershell -ExecutionPolicy Bypass -File .\install.ps1

    Configuration is read from environment variables because a piped
    `irm | iex` script cannot accept param() arguments:

        $env:CBOOT_LANG         = 'en'          # fr | en (default fr)
        $env:CBOOT_TOOLCHAINS   = 'cpp,rust'    # cpp dotnet rust go python java
        $env:CBOOT_EDITOR       = 'vscode,vim'  # vscode kate vim, or none
        $env:CBOOT_ASSUME_YES   = '1'           # accept every default
        $env:CBOOT_STD          = 'gnu89'       # standard for the C verify step
        $env:CBOOT_MSYS2_ROOT   = 'C:\msys64'
        $env:CBOOT_SCAFFOLD_DIR = 'C:\dev\hello'
#>

$ErrorActionPreference = 'Stop'

# Accented French is unreadable in a legacy code page. Switching the console to
# UTF-8 is harmless for English and is what makes "chaîne" render correctly.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

function Get-EnvOrDefault {
    param([string]$Name, [string]$Default)
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

# French is the default, because that is who this was written for. English is a
# first-class option, not an afterthought: when the language was not pinned via
# the environment, the very first thing the script does is ask, bilingually.
$LanguageWasPinned = -not [string]::IsNullOrWhiteSpace(
    [Environment]::GetEnvironmentVariable('CBOOT_LANG', 'Process'))

$Config = @{
    Msys2Root   = Get-EnvOrDefault 'CBOOT_MSYS2_ROOT' 'C:\msys64'
    Standard    = Get-EnvOrDefault 'CBOOT_STD'        'gnu89'
    ScaffoldDir = Get-EnvOrDefault 'CBOOT_SCAFFOLD_DIR' ''
    Toolchains  = Get-EnvOrDefault 'CBOOT_TOOLCHAINS' ''
    Editor      = Get-EnvOrDefault 'CBOOT_EDITOR' ''
    Language    = (Get-EnvOrDefault 'CBOOT_LANG' 'fr').ToLower()
    AssumeYes   = (Get-EnvOrDefault 'CBOOT_ASSUME_YES' '0') -eq '1'
    MaxRetries  = 5
}

# CBOOT_PROFILE predates multi-toolchain support. Keep it working rather than
# breaking anyone who copied an older command line.
$legacyProfile = Get-EnvOrDefault 'CBOOT_PROFILE' ''
if ($legacyProfile -and -not $Config.Toolchains) {
    switch ($legacyProfile.ToLower()) {
        'c'    { $Config.Toolchains = 'cpp'; if (-not $Config.Editor) { $Config.Editor = 'none' } }
        'cpp'  { $Config.Toolchains = 'cpp'; if (-not $Config.Editor) { $Config.Editor = 'none' } }
        'full' { $Config.Toolchains = 'cpp' }
    }
}
if ((Get-EnvOrDefault 'CBOOT_SKIP_VSCODE' '0') -eq '1' -and -not $Config.Editor) {
    $Config.Editor = 'none'
}

$AllToolchains = @('cpp', 'dotnet', 'rust', 'go', 'python', 'java')
$AllEditors    = @('vscode', 'kate', 'vim')

# --------------------------------------------------------------------------
# Input validation
#
# These values are user-supplied environment variables that end up inside a
# generated Makefile, a JSON config, the registry PATH, and installer
# arguments. Validate them once, here, rather than at each use site.
# --------------------------------------------------------------------------

if ($Config.Language -notin @('en', 'fr')) {
    throw "Unknown CBOOT_LANG='$($Config.Language)' (expected en or fr)"
}

$AllowedStandards = @(
    'c89', 'c90', 'c99', 'c11', 'c17', 'c18', 'c23',
    'gnu89', 'gnu90', 'gnu99', 'gnu11', 'gnu17', 'gnu18', 'gnu23'
)
if ($Config.Standard -notin $AllowedStandards) {
    throw "Refusing to use CBOOT_STD='$($Config.Standard)'. Allowed: $($AllowedStandards -join ', ')"
}

# A semicolon here would not extend the path, it would append a second PATH
# entry when this is written to the registry - an easy way to smuggle an
# attacker-controlled directory ahead of the real tools.
if ($Config.Msys2Root -match '[;"''|&<>`]' -or $Config.Msys2Root -match "[`r`n]") {
    throw "CBOOT_MSYS2_ROOT contains characters that are not valid in a path: '$($Config.Msys2Root)'"
}
if (-not [System.IO.Path]::IsPathRooted($Config.Msys2Root)) {
    throw "CBOOT_MSYS2_ROOT must be an absolute path, got '$($Config.Msys2Root)'"
}
if ($Config.Msys2Root -match '^\\\\') {
    throw "CBOOT_MSYS2_ROOT must be a local path, not a UNC share: '$($Config.Msys2Root)'"
}

# MSYS2 subsystem. UCRT64 is the modern default: it links against the
# Universal CRT that ships with Windows 10+ rather than the legacy msvcrt.
$SubsystemDir   = 'ucrt64'
$PackageGroup   = 'mingw-w64-ucrt-x86_64-toolchain'
$Msys2Installer = 'https://repo.msys2.org/distrib/msys2-x86_64-latest.exe'
$BinDir         = Join-Path $Config.Msys2Root "$SubsystemDir\bin"

# --------------------------------------------------------------------------
# Messages
# --------------------------------------------------------------------------

$Messages = @{
    'title'          = @{ en = 'Universal Development Environment Installer';         fr = "Installateur universel d'environnement de développement" }
    'built_for'      = @{ en = 'Built for Universite Sorbonne Paris Nord (Paris 13)'; fr = "Conçu pour les étudiants de l'Université Sorbonne" }
    'built_for2'     = @{ en = 'students, and for anyone else who needs a toolchain.'; fr = 'Paris Nord (Paris 13), et pour tous les autres.' }
    'not_affiliated' = @{ en = 'Not affiliated with the university -- usable by anyone.'; fr = "Sans lien avec l'université -- utilisable par tous." }
    'detected'       = @{ en = 'Detected: Windows {0}';                               fr = 'Détecté : Windows {0}' }

    'tc_cpp'         = @{ en = 'C / C++       - gcc, g++, gdb, make';                 fr = 'C / C++       - gcc, g++, gdb, make' }
    'tc_dotnet'      = @{ en = 'C#            - .NET SDK';                            fr = 'C#            - SDK .NET' }
    'tc_rust'        = @{ en = 'Rust          - rustup, cargo, rustc';                fr = 'Rust          - rustup, cargo, rustc' }
    'tc_go'          = @{ en = 'Go            - go compiler and tools';               fr = 'Go            - compilateur et outils Go' }
    'tc_python'      = @{ en = 'Python        - python3 and pip';                     fr = 'Python        - python3 et pip' }
    'tc_java'        = @{ en = 'Java          - JDK (javac, java)';                   fr = 'Java          - JDK (javac, java)' }

    'q_tc'           = @{ en = 'Which languages do you want?';                        fr = 'Quels langages voulez-vous ?' }
    'q_multi'        = @{ en = 'Pick one or several, separated by commas (e.g. 1,3)'; fr = 'Choisissez-en un ou plusieurs, séparés par des virgules (ex. 1,3)' }
    'q_tc_ask'       = @{ en = 'Languages';                                           fr = 'Langages' }
    'q_editor'       = @{ en = 'Which editors do you want?';                          fr = 'Quels éditeurs voulez-vous ?' }
    'ed_vscode'      = @{ en = 'Visual Studio Code  - full IDE, debugger, IntelliSense'; fr = 'Visual Studio Code  - IDE complet, débogueur, IntelliSense' }
    'ed_kate'        = @{ en = 'Kate                - lightweight KDE editor';        fr = 'Kate                - éditeur KDE léger' }
    'ed_vim'         = @{ en = 'Vim                 - terminal editor, always available'; fr = 'Vim                 - éditeur en terminal, toujours disponible' }
    'ed_none'        = @{ en = '0) None - I already have an editor';                  fr = "0) Aucun - j'ai déjà un éditeur" }
    'q_editor_ask'   = @{ en = 'Editors';                                             fr = 'Éditeurs' }
    'q_yn'           = @{ en = '{0} (y/n)';                                           fr = '{0} (o/n)' }
    'q_reinstall'    = @{ en = '{0} is already installed. Reinstall/repair anyway?';  fr = '{0} est déjà installé. Réinstaller/réparer quand même ?' }
    'q_continue'     = @{ en = 'Continue anyway?';                                    fr = 'Continuer quand même ?' }
    'e_badpick'      = @{ en = 'Unknown choice: {0}';                                 fr = 'Choix inconnu : {0}' }
    'e_nopick'       = @{ en = 'Nothing selected - nothing to do.';                   fr = 'Aucune sélection - rien à faire.' }

    's_install_tc'   = @{ en = 'Installing {0}';                                      fr = 'Installation de {0}' }
    's_editors'      = @{ en = 'Installing editors';                                  fr = 'Installation des éditeurs' }
    's_scaffold'     = @{ en = 'Creating the starter project';                        fr = 'Création du projet de départ' }
    's_verify'       = @{ en = 'Verifying';                                           fr = 'Vérification' }

    'not_admin'      = @{ en = 'Not running as Administrator - installers may raise a UAC prompt.'; fr = 'Pas de droits administrateur - une invite UAC peut apparaître.' }
    'already'        = @{ en = '{0} already installed ({1})';                         fr = '{0} est déjà installé ({1})' }
    'keeping'        = @{ en = 'Keeping the existing installation';                   fr = 'Installation existante conservée' }
    'tc_ok'          = @{ en = '{0} installed';                                       fr = '{0} installé' }
    'tc_failed'      = @{ en = '{0} installation failed - continuing with the rest';   fr = "Échec de l'installation de {0} - on continue" }
    'nowinget'       = @{ en = 'winget is unavailable - cannot install {0} automatically'; fr = "winget indisponible - impossible d'installer {0} automatiquement" }
    'winget_inst'    = @{ en = 'Installing {0} via winget';                           fr = 'Installation de {0} via winget' }

    'path_have'      = @{ en = 'Already on PATH: {0}';                                fr = 'Déjà dans le PATH : {0}' }
    'path_added'     = @{ en = 'Added to user PATH: {0}';                             fr = 'Ajouté au PATH utilisateur : {0}' }
    'path_long'      = @{ en = "User PATH is {0} chars; adding '{1}' risks truncation. Remove stale entries first."; fr = "Le PATH utilisateur fait {0} caractères ; ajouter '{1}' risque de le tronquer." }

    'msys2_have'     = @{ en = 'MSYS2 already present at {0}';                        fr = 'MSYS2 est déjà présent dans {0}' }
    'msys2_ok'       = @{ en = 'MSYS2 installed at {0}';                              fr = 'MSYS2 installé dans {0}' }
    'msys2_none'     = @{ en = 'MSYS2 not found - installing';                        fr = 'MSYS2 introuvable - installation en cours' }
    'msys2_fallback' = @{ en = 'Falling back to the official MSYS2 installer';        fr = "Bascule vers l'installateur officiel MSYS2" }
    'msys2_fail'     = @{ en = 'MSYS2 installation failed. Install it manually from https://www.msys2.org and re-run.'; fr = "Échec de l'installation de MSYS2. Installez-le depuis https://www.msys2.org puis relancez." }
    'sig_ok'         = @{ en = 'Installer signature valid';                           fr = "Signature de l'installateur valide" }
    'sig_by'         = @{ en = 'Signed by: {0}';                                      fr = 'Signé par : {0}' }
    'sig_bad'        = @{ en = "Refusing to run the MSYS2 installer: signature status is '{0}'."; fr = "Refus d'exécuter l'installateur MSYS2 : statut de signature '{0}'." }
    'sig_unexpected' = @{ en = 'That is not the signer this script expects for MSYS2.'; fr = "Ce n'est pas le signataire attendu pour MSYS2." }
    'sig_aborted'    = @{ en = 'Aborted at the signature check.';                     fr = 'Interrompu lors de la vérification de signature.' }
    'tc_refresh'     = @{ en = 'Refreshing and upgrading packages';                   fr = 'Actualisation et mise à jour des paquets' }
    'tc_attempt'     = @{ en = 'Installing {0} (attempt {1}/{2})';                    fr = 'Installation de {0} (tentative {1}/{2})' }
    'tc_retry'       = @{ en = 'Attempt failed (usually a mirror timeout) - retrying'; fr = 'Tentative échouée (souvent un miroir trop lent) - nouvelle tentative' }
    'tc_giveup'      = @{ en = 'Toolchain install failed after {0} attempts.';        fr = "Échec de l'installation après {0} tentatives." }

    'ext_check'      = @{ en = 'Ensuring the language extensions are present';        fr = 'Vérification des extensions de langage' }
    'ext_have'       = @{ en = 'Extension {0} already installed';                     fr = 'Extension {0} déjà installée' }
    'ext_ok'         = @{ en = 'Extension {0} installed';                             fr = 'Extension {0} installée' }
    'ext_fail'       = @{ en = 'Could not install extension {0}';                     fr = "Impossible d'installer l'extension {0}" }
    'clangd_ok'      = @{ en = 'clangd installed - enable the LSP Client plugin in Kate'; fr = 'clangd installé - activez le plugin LSP Client dans Kate' }
    'clangd_no'      = @{ en = 'clangd unavailable - Kate still works, just without completion'; fr = 'clangd indisponible - Kate fonctionne, mais sans complétion' }
    'vimrc_ok'       = @{ en = 'Wrote a starter _vimrc (syntax, indentation, line numbers)'; fr = 'Fichier _vimrc de départ créé (syntaxe, indentation, numéros)' }
    'vimrc_kept'     = @{ en = 'You already have a vim config - left untouched';      fr = 'Vous avez déjà une configuration vim - laissée intacte' }

    'v_missing'      = @{ en = '{0} is not on PATH after installation';               fr = "{0} n'est pas dans le PATH après l'installation" }
    'v_ok'           = @{ en = '{0} works';                                           fr = '{0} fonctionne' }
    'v_fail'         = @{ en = '{0} failed its check';                                fr = '{0} a échoué à sa vérification' }
    'v_comments'     = @{ en = 'Both /* */ and // comment styles accepted (-std={0})'; fr = 'Les commentaires /* */ et // sont acceptés (-std={0})' }
    'v_newshell'     = @{ en = '{0} needs a new terminal before it is on PATH';       fr = '{0} nécessite un nouveau terminal pour être dans le PATH' }

    'sc_kept'        = @{ en = 'Kept existing {0}';                                   fr = 'Fichier {0} conservé' }
    'sc_ok'          = @{ en = 'Starter project created at {0}';                      fr = 'Projet de départ créé dans {0}' }

    'done_title'     = @{ en = 'Installation complete';                               fr = 'Installation terminée' }
    'summary'        = @{ en = 'What you have now:';                                  fr = 'Ce dont vous disposez :' }
    'reopen'         = @{ en = 'Open a NEW terminal before using the new tools.';     fr = 'Ouvrez un NOUVEAU terminal avant d''utiliser les nouveaux outils.' }
    'resume1'        = @{ en = 'Re-run the installer to resume - completed steps are skipped'; fr = "Relancez l'installateur pour reprendre - les étapes terminées" }
    'resume2'        = @{ en = 'and partial downloads are reused from the package cache.'; fr = 'sont ignorées et les téléchargements partiels sont réutilisés.' }
    'cannot_prompt'  = @{ en = "Cannot prompt here - using default '{0}'";            fr = "Impossible de poser la question ici - valeur par défaut '{0}'" }
}

function T {
    param([string]$Key)
    $rest = @($args)
    if (-not $Messages.ContainsKey($Key)) { return $Key }
    $text = $Messages[$Key][$Config.Language]
    if ([string]::IsNullOrEmpty($text)) { $text = $Messages[$Key]['en'] }
    if ($rest.Count -gt 0) { return ($text -f $rest) }
    return $text
}

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

function Write-Step {
    param([int]$Number, [int]$Total, [string]$Message)
    Write-Host ''
    Write-Host "[$Number/$Total] $Message" -ForegroundColor Cyan
}
function Write-Ok   { param([string]$M) Write-Host "      OK   $M" -ForegroundColor Green }
function Write-Note { param([string]$M) Write-Host "      ..   $M" -ForegroundColor DarkGray }
function Write-Warn { param([string]$M) Write-Host "      WARN $M" -ForegroundColor Yellow }
function Write-Fail { param([string]$M) Write-Host "      FAIL $M" -ForegroundColor Red }

function Write-Banner {
    Write-Host ''
    Write-Host '  =============================================' -ForegroundColor Cyan
    Write-Host ("   cready -- " + (T 'title')) -ForegroundColor Cyan
    Write-Host '  =============================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ("   " + (T 'built_for'))
    Write-Host ("   " + (T 'built_for2'))
    Write-Host ("   " + (T 'not_affiliated')) -ForegroundColor DarkGray
    Write-Host ''
    # Always shown, in both languages, whichever one is active.
    Write-Host '   Francais / English  --  $env:CBOOT_LANG=''fr'' | ''en''' -ForegroundColor Cyan
    Write-Host ''
}

# --------------------------------------------------------------------------
# Interaction
# --------------------------------------------------------------------------

# `irm | iex` still has a live console, so Read-Host works. It does not when
# the script runs from a scheduled task or CI, so degrade to the default.
function Test-CanPrompt {
    if ($Config.AssumeYes) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    try {
        if ([Console]::IsInputRedirected) { return $false }
    }
    catch { return $false }
    return $true
}

function Read-Answer {
    param([string]$Question, [string]$Default)
    if (-not (Test-CanPrompt)) {
        Write-Host "      $Question [auto: $Default]" -ForegroundColor DarkGray
        return $Default
    }
    try {
        $reply = Read-Host "   $Question [$Default]"
    }
    catch {
        Write-Note (T 'cannot_prompt' $Default)
        return $Default
    }
    if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
    return $reply.Trim()
}

# Accepts o/O for "oui" as well as y/Y, so a French prompt behaves.
function Read-Confirm {
    param([string]$Question, [switch]$DefaultNo)
    $default = if ($DefaultNo) { 'n' } elseif ($Config.Language -eq 'fr') { 'o' } else { 'y' }
    return (Read-Answer (T 'q_yn' $Question) $default) -match '^[YyOo]'
}

# Asked before anything else, and printed in both languages, so an English
# speaker never has to guess. Skipped entirely when CBOOT_LANG was set.
function Get-Language {
    if (-not (Test-CanPrompt)) { return 'fr' }
    Write-Host ''
    Write-Host '   +---------------------------------------+'
    Write-Host '   |   Langue  /  Language                 |'
    Write-Host '   +---------------------------------------+'
    Write-Host ''
    Write-Host '     1) Francais   (par defaut / default)'
    Write-Host '     2) English'
    Write-Host ''
    switch (Read-Answer 'Choisissez / Choose' '1') {
        '2'     { return 'en' }
        default { return 'fr' }
    }
}

# Turns "1,3" into ids drawn from $Ids. Throws on an out-of-range number so a
# typo is reported rather than silently installing nothing.
function Convert-Choice {
    # Deliberately not named $Input: that is an automatic variable holding the
    # pipeline enumerator, and a parameter of that name silently binds nothing.
    param([string]$Selection, [string[]]$Ids)
    $out = @()
    foreach ($token in ($Selection -split '[,\s]+' | Where-Object { $_ -ne '' })) {
        if ($token -notmatch '^\d+$') { throw (T 'e_badpick' $token) }
        $n = [int]$token
        if ($n -lt 1 -or $n -gt $Ids.Count) { throw (T 'e_badpick' $token) }
        $id = $Ids[$n - 1]
        if ($out -notcontains $id) { $out += $id }
    }
    return $out
}

function Get-Toolchains {
    if ($Config.Toolchains) {
        return @($Config.Toolchains -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { $_.ToLower() })
    }
    if (-not (Test-CanPrompt)) { return @('cpp') }

    Write-Host ''
    Write-Host ("   " + (T 'q_tc'))
    Write-Host ("   " + (T 'q_multi')) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ("     1) " + (T 'tc_cpp'))
    Write-Host ("     2) " + (T 'tc_dotnet'))
    Write-Host ("     3) " + (T 'tc_rust'))
    Write-Host ("     4) " + (T 'tc_go'))
    Write-Host ("     5) " + (T 'tc_python'))
    Write-Host ("     6) " + (T 'tc_java'))
    Write-Host ''

    while ($true) {
        try { return (Convert-Choice (Read-Answer (T 'q_tc_ask') '1') $AllToolchains) }
        catch {
            Write-Warn $_.Exception.Message
            if (-not (Test-CanPrompt)) { return @('cpp') }
        }
    }
}

function Get-Editors {
    if ($Config.Editor) {
        if ($Config.Editor.ToLower() -eq 'none') { return @() }
        return @($Config.Editor -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { $_.ToLower() })
    }
    if (-not (Test-CanPrompt)) { return @() }

    Write-Host ''
    Write-Host ("   " + (T 'q_editor'))
    Write-Host ("   " + (T 'q_multi')) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ("     1) " + (T 'ed_vscode'))
    Write-Host ("     2) " + (T 'ed_kate'))
    Write-Host ("     3) " + (T 'ed_vim'))
    Write-Host ("     " + (T 'ed_none'))
    Write-Host ''

    while ($true) {
        $answer = Read-Answer (T 'q_editor_ask') '1'
        if ($answer -eq '0') { return @() }
        try { return (Convert-Choice $answer $AllEditors) }
        catch {
            Write-Warn $_.Exception.Message
            if (-not (Test-CanPrompt)) { return @() }
        }
    }
}

# --------------------------------------------------------------------------
# Environment helpers
# --------------------------------------------------------------------------

# A freshly installed program is invisible to this process until the registry
# PATH is re-read, because the environment block was copied at process start.
function Sync-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Resolve-Tool {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-ToUserPath {
    param([string]$Directory)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $current) { $current = '' }

    foreach ($entry in ($current -split ';' | Where-Object { $_ -ne '' })) {
        if ($entry.TrimEnd('\') -ieq $Directory.TrimEnd('\')) {
            Write-Ok (T 'path_have' $Directory)
            return
        }
    }

    $updated = ($current.TrimEnd(';') + ';' + $Directory).TrimStart(';')

    # The user PATH is stored as REG_EXPAND_SZ and silently truncates past
    # ~2047 characters, which would destroy existing entries. Refuse instead.
    if ($updated.Length -gt 1900) {
        throw (T 'path_long' $updated.Length $Directory)
    }

    [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
    Sync-ProcessPath
    Write-Ok (T 'path_added' $Directory)
}

# Shared winget wrapper. Everything except the C/C++ toolchain comes from
# winget, so the retry/reporting logic lives in one place.
function Install-ViaWinget {
    param([string]$Id, [string]$Label, [string[]]$ExtraArgs = @())

    $winget = Resolve-Tool 'winget'
    if (-not $winget) {
        Write-Warn (T 'nowinget' $Label)
        return $false
    }

    Write-Note (T 'winget_inst' $Label)
    $argList = @('install', '--id', $Id, '-e', '--source', 'winget',
                 '--accept-package-agreements', '--accept-source-agreements') + $ExtraArgs
    & $winget @argList 2>&1 | ForEach-Object { Write-Note $_ }
    Sync-ProcessPath
    return $true
}

# --------------------------------------------------------------------------
# MSYS2 / pacman (C and C++ only)
# --------------------------------------------------------------------------

function Invoke-Pacman {
    param([string]$Arguments)

    $bash = Join-Path $Config.Msys2Root 'usr\bin\bash.exe'
    if (-not (Test-Path $bash)) { throw "MSYS2 bash not found at $bash" }

    $previous = $env:MSYSTEM
    $env:MSYSTEM = $SubsystemDir.ToUpper()
    try {
        # -l gives a login shell so pacman sees a sane MSYS2 environment.
        & $bash -lc "pacman $Arguments" 2>&1 | ForEach-Object { Write-Note $_ }
        return $LASTEXITCODE
    }
    finally { $env:MSYSTEM = $previous }
}

# Refuses to run a downloaded binary whose Authenticode signature is missing or
# broken. If the signature is valid but from an unexpected signer, the signer is
# shown and confirmation is required, because MSYS2's signing identity can
# legitimately change between releases and hardcoding one would break installs.
function Assert-TrustedInstaller {
    param([string]$Path)

    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($signature.Status -ne 'Valid') { throw (T 'sig_bad' $signature.Status) }

    $signer = $signature.SignerCertificate.Subject
    Write-Ok (T 'sig_ok')
    Write-Note (T 'sig_by' $signer)

    if ($signer -notmatch 'MSYS2|Christoph Reiter') {
        Write-Warn (T 'sig_unexpected')
        if (-not (Read-Confirm (T 'q_continue'))) { throw (T 'sig_aborted') }
    }
}

function Install-Msys2 {
    if (Test-Path (Join-Path $Config.Msys2Root 'usr\bin\bash.exe')) {
        Write-Ok (T 'msys2_have' $Config.Msys2Root)
        return
    }

    Write-Note (T 'msys2_none')
    Install-ViaWinget -Id 'MSYS2.MSYS2' -Label 'MSYS2' | Out-Null

    if (-not (Test-Path (Join-Path $Config.Msys2Root 'usr\bin\bash.exe'))) {
        Write-Note (T 'msys2_fallback')

        # Random filename: a fixed name in %TEMP% is guessable and could be
        # pre-created as a junction pointing somewhere else.
        $temp = Join-Path $env:TEMP ("msys2-" + [IO.Path]::GetRandomFileName() + ".exe")
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Msys2Installer -OutFile $temp -UseBasicParsing

        try {
            # This is the first binary the whole chain executes, so it does not
            # run unverified. HTTPS protects it in transit but says nothing
            # about the file itself if the origin or a cache were tampered with.
            Assert-TrustedInstaller -Path $temp
            $root = $Config.Msys2Root -replace '\\', '/'
            Start-Process -FilePath $temp -Wait -ArgumentList @(
                'in', '--confirm-command', '--accept-messages', '--root', $root
            )
        }
        finally { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
    }

    if (-not (Test-Path (Join-Path $Config.Msys2Root 'usr\bin\bash.exe'))) {
        throw (T 'msys2_fail')
    }
    Write-Ok (T 'msys2_ok' $Config.Msys2Root)
}

function Install-CppToolchain {
    Install-Msys2

    if (-not (Test-Path (Join-Path $BinDir 'gcc.exe'))) {
        # -Syu, not -Sy. MSYS2 documents partial upgrades as unsupported:
        # syncing the database without upgrading can install packages built
        # against newer libraries than the ones on disk.
        Write-Note (T 'tc_refresh')
        Invoke-Pacman '-Syu --noconfirm' | Out-Null

        # MSYS2 mirrors time out fairly often mid-transaction. Completed
        # downloads stay in the pacman cache, so each retry resumes.
        $installed = $false
        for ($attempt = 1; $attempt -le $Config.MaxRetries; $attempt++) {
            Write-Note (T 'tc_attempt' $PackageGroup $attempt $Config.MaxRetries)
            $code = Invoke-Pacman "-S --needed --noconfirm $PackageGroup"
            if ($code -eq 0 -and (Test-Path (Join-Path $BinDir 'gcc.exe'))) { $installed = $true; break }
            Write-Warn (T 'tc_retry')
        }
        if (-not $installed) { throw (T 'tc_giveup' $Config.MaxRetries) }
    }

    Add-ToUserPath -Directory $BinDir
    Write-Ok (T 'tc_ok' 'C / C++')
}

# --------------------------------------------------------------------------
# Toolchain registry
# --------------------------------------------------------------------------

function Get-ToolchainLabel {
    param([string]$Id)
    switch ($Id) {
        'cpp'    { return 'C / C++' }
        'dotnet' { return 'C# (.NET)' }
        'rust'   { return 'Rust' }
        'go'     { return 'Go' }
        'python' { return 'Python' }
        'java'   { return 'Java' }
        default  { return $Id }
    }
}

function Get-ToolchainProbe {
    param([string]$Id)
    switch ($Id) {
        'cpp'    { return 'gcc' }
        'dotnet' { return 'dotnet' }
        'rust'   { return 'rustc' }
        'go'     { return 'go' }
        'python' { return 'python' }
        'java'   { return 'javac' }
        default  { return $Id }
    }
}

function Install-Toolchain {
    param([string]$Id)

    $label = Get-ToolchainLabel $Id
    $probe = Get-ToolchainProbe $Id

    Sync-ProcessPath
    $existing = Resolve-Tool $probe
    if ($existing) {
        Write-Ok (T 'already' $label $existing)
        # Re-installing something that already works is the surprising choice,
        # so an unattended run must default to keeping it.
        if (-not (Read-Confirm (T 'q_reinstall' $label) -DefaultNo)) {
            Write-Note (T 'keeping')
            return
        }
    }

    switch ($Id) {
        'cpp'    { Install-CppToolchain; return }
        'dotnet' { Install-ViaWinget -Id 'Microsoft.DotNet.SDK.8'  -Label $label | Out-Null }
        'rust'   { Install-ViaWinget -Id 'Rustlang.Rustup'         -Label $label | Out-Null }
        'go'     { Install-ViaWinget -Id 'GoLang.Go'               -Label $label | Out-Null }
        'python' { Install-ViaWinget -Id 'Python.Python.3.12'      -Label $label | Out-Null }
        'java'   { Install-ViaWinget -Id 'Microsoft.OpenJDK.21'    -Label $label | Out-Null }
    }

    Sync-ProcessPath
    if (Resolve-Tool $probe) {
        Write-Ok (T 'tc_ok' $label)
    }
    else {
        # winget frequently installs correctly but the new PATH only reaches
        # brand-new processes, so this is a warning rather than a failure.
        Write-Warn (T 'v_newshell' $label)
    }
}

# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------

# Runs an external tool and returns its combined output plus exit code without
# letting stderr become a terminating error. PowerShell 5.1 wraps a native
# command's stderr in ErrorRecords, which $ErrorActionPreference='Stop' would
# otherwise turn into an exception - a tool printing a warning is not a crash.
function Invoke-Capture {
    param([string]$Exe, [string[]]$Arguments = @())
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& $Exe @Arguments 2>&1 | Out-String)
        return @{ Output = $text; Code = $LASTEXITCODE }
    }
    catch { return @{ Output = $_.Exception.Message; Code = -1 } }
    finally { $ErrorActionPreference = $previous }
}

function Test-Toolchain {
    param([string]$Id)

    Sync-ProcessPath
    $label = Get-ToolchainLabel $Id
    $probe = Get-ToolchainProbe $Id
    if (-not (Resolve-Tool $probe)) {
        Write-Warn (T 'v_missing' $label)
        return
    }

    $work = Join-Path $env:TEMP ('cready-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    try {
        switch ($Id) {
            'cpp' {
                # Mixes ANSI block comments with // line comments, so a pass
                # proves the configured standard accepts both styles.
                $src = Join-Path $work 'v.c'
                @'
#include <stdio.h>
/* ANSI C style block comment */
int main(void)
{
    int value = 42;   // line comment - rejected by strict c89
    printf("OK %d\n", value);
    return 0;
}
'@ | Set-Content -Path $src -Encoding ASCII
                $exe = Join-Path $work 'v.exe'
                Invoke-Capture (Resolve-Tool 'gcc') @("-std=$($Config.Standard)", '-Wall', '-Wextra', $src, '-o', $exe) | Out-Null
                if ((Test-Path $exe) -and ((Invoke-Capture $exe).Output -match 'OK 42')) {
                    Write-Ok (T 'v_ok' 'C')
                    Write-Ok (T 'v_comments' $Config.Standard)
                }
                else { Write-Warn (T 'v_fail' 'C') }

                if (Resolve-Tool 'g++') {
                    $csrc = Join-Path $work 'v.cpp'
                    @'
#include <iostream>
#include <vector>
int main() { std::vector<int> v{1,2,3}; for (int i : v) std::cout << i; std::cout << " OK\n"; }
'@ | Set-Content -Path $csrc -Encoding ASCII
                    $cexe = Join-Path $work 'vpp.exe'
                    Invoke-Capture (Resolve-Tool 'g++') @('-std=c++17', $csrc, '-o', $cexe) | Out-Null
                    if ((Test-Path $cexe) -and ((Invoke-Capture $cexe).Output -match 'OK')) { Write-Ok (T 'v_ok' 'C++') }
                    else { Write-Warn (T 'v_fail' 'C++') }
                }
            }
            'rust' {
                $src = Join-Path $work 'v.rs'
                'fn main() { println!("OK"); }' | Set-Content -Path $src -Encoding ASCII
                $exe = Join-Path $work 'v.exe'
                Invoke-Capture (Resolve-Tool 'rustc') @($src, '-o', $exe) | Out-Null
                if ((Test-Path $exe) -and ((Invoke-Capture $exe).Output -match 'OK')) { Write-Ok (T 'v_ok' $label) }
                else { Write-Warn (T 'v_fail' $label) }
            }
            'go' {
                $src = Join-Path $work 'v.go'
                "package main`nimport `"fmt`"`nfunc main() { fmt.Println(`"OK`") }" |
                    Set-Content -Path $src -Encoding ASCII
                $out = (Invoke-Capture (Resolve-Tool 'go') @('run', $src)).Output
                if ($out -match 'OK') { Write-Ok (T 'v_ok' $label) } else { Write-Warn (T 'v_fail' $label) }
            }
            'python' {
                $out = (Invoke-Capture (Resolve-Tool 'python') @('-c', 'print("OK")')).Output
                if ($out -match 'OK') { Write-Ok (T 'v_ok' $label) } else { Write-Warn (T 'v_fail' $label) }
            }
            'java' {
                $src = Join-Path $work 'Hello.java'
                'public class Hello { public static void main(String[] a) { System.out.println("OK"); } }' |
                    Set-Content -Path $src -Encoding ASCII
                Invoke-Capture (Resolve-Tool 'javac') @($src) | Out-Null
                Push-Location $work
                try { $out = (Invoke-Capture (Resolve-Tool 'java') @('Hello')).Output } finally { Pop-Location }
                if ($out -match 'OK') { Write-Ok (T 'v_ok' $label) } else { Write-Warn (T 'v_fail' $label) }
            }
            'dotnet' {
                # `dotnet new` + build costs tens of seconds on first run, so
                # this checks the SDK is registered rather than building.
                $out = (Invoke-Capture (Resolve-Tool 'dotnet') @('--list-sdks')).Output
                if ($out -match '\d') { Write-Ok (T 'v_ok' $label) } else { Write-Warn (T 'v_fail' $label) }
            }
        }
    }
    finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}

# --------------------------------------------------------------------------
# Editors
# --------------------------------------------------------------------------

function Find-VSCode {
    $candidates = @(
        (Resolve-Tool 'code'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:ProgramFiles  'Microsoft VS Code\bin\code.cmd')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Install-VSCode {
    $code = Find-VSCode
    if ($code) { Write-Ok (T 'already' 'VS Code' $code) }
    else {
        Install-ViaWinget -Id 'Microsoft.VisualStudioCode' -Label 'VS Code' -ExtraArgs @('--scope', 'user') | Out-Null
        $code = Find-VSCode
        if (-not $code) { Write-Warn (T 'tc_failed' 'VS Code'); return }
        Write-Ok (T 'tc_ok' 'VS Code')
    }

    # Extensions follow the languages that were actually installed, so a
    # Python-only setup does not drag in the C/C++ toolset and vice versa.
    Write-Note (T 'ext_check')
    $installed = & $code --list-extensions 2>$null
    foreach ($id in $Script:SelectedToolchains) {
        $ext = switch ($id) {
            'cpp'    { 'ms-vscode.cpptools' }
            'dotnet' { 'ms-dotnettools.csharp' }
            'rust'   { 'rust-lang.rust-analyzer' }
            'go'     { 'golang.go' }
            'python' { 'ms-python.python' }
            'java'   { 'redhat.java' }
            default  { $null }
        }
        if (-not $ext) { continue }
        if ($installed -contains $ext) { Write-Ok (T 'ext_have' $ext); continue }
        & $code --install-extension $ext --force 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok (T 'ext_ok' $ext) } else { Write-Warn (T 'ext_fail' $ext) }
    }
}

function Find-Kate {
    $candidates = @(
        (Resolve-Tool 'kate'),
        (Join-Path $env:ProgramFiles        'Kate\bin\kate.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Kate\bin\kate.exe'),
        (Join-Path $env:LOCALAPPDATA        'Programs\Kate\bin\kate.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Install-Kate {
    $kate = Find-Kate
    if ($kate) { Write-Ok (T 'already' 'Kate' $kate) }
    else {
        Install-ViaWinget -Id 'KDE.Kate' -Label 'Kate' | Out-Null
        $kate = Find-Kate
        if (-not $kate) { Write-Warn (T 'tc_failed' 'Kate'); return }
        Write-Ok (T 'tc_ok' 'Kate')
    }

    # Kate has no built-in C parser; its LSP plugin drives clangd. Only worth
    # installing when a C/C++ toolchain was actually selected.
    if ($Script:SelectedToolchains -notcontains 'cpp') { return }
    if (Resolve-Tool 'clangd') { Write-Ok (T 'already' 'clangd' (Resolve-Tool 'clangd')); return }

    $code = Invoke-Pacman '-S --needed --noconfirm mingw-w64-ucrt-x86_64-clang-tools-extra'
    Sync-ProcessPath
    if ($code -eq 0 -and (Resolve-Tool 'clangd')) { Write-Ok (T 'clangd_ok') }
    else { Write-Warn (T 'clangd_no') }
}

function Install-Vim {
    $vim = Resolve-Tool 'vim'
    if ($vim) { Write-Ok (T 'already' 'Vim' $vim) }
    else {
        Install-ViaWinget -Id 'vim.vim' -Label 'Vim' | Out-Null
        $vim = Resolve-Tool 'vim'
        if (-not $vim) { Write-Warn (T 'v_newshell' 'Vim') }
        else { Write-Ok (T 'tc_ok' 'Vim') }
    }
    Write-VimRc
}

# A stock vim has no syntax highlighting and 8-wide tabs, which is a rough
# first impression. Only ever written when the user has no vim config at all.
function Write-VimRc {
    $rc = Join-Path $env:USERPROFILE '_vimrc'
    $alt = Join-Path $env:USERPROFILE '.vimrc'
    if ((Test-Path $rc) -or (Test-Path $alt)) {
        Write-Note (T 'vimrc_kept')
        return
    }
    @'
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
'@ | Set-Content -Path $rc -Encoding ASCII
    Write-Ok (T 'vimrc_ok')
}

# --------------------------------------------------------------------------
# Starter project (C only -- the course this was written for)
# --------------------------------------------------------------------------

# Never overwrite. CBOOT_SCAFFOLD_DIR is just a path, so it is easy to aim at a
# real project by accident; silently replacing a tuned launch.json would
# destroy the student's work.
function Write-IfAbsent {
    param([string]$Path, [string]$Content)
    if (Test-Path $Path) { Write-Note (T 'sc_kept' (Split-Path $Path -Leaf)); return }
    Set-Content -Path $Path -Value $Content -Encoding ASCII
}

function New-Scaffold {
    param([string]$Directory)

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $vscodeDir = Join-Path $Directory '.vscode'
    New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null

    $gccPath = Join-Path $BinDir 'gcc.exe'
    $gdbPath = Join-Path $BinDir 'gdb.exe'
    # JSON needs each backslash doubled. Use the literal string method rather
    # than -replace, whose replacement text handles backslashes differently.
    $gccJson = $gccPath.Replace('\', '\\')
    $gdbJson = $gdbPath.Replace('\', '\\')

    $mainFile = Join-Path $Directory 'main.c'
    if (-not (Test-Path $mainFile)) {
        @'
#include <stdio.h>

/* ANSI C with // comments enabled via -std=gnu89 */
int main(void)
{
    printf("Hello, C!\n");   // press F5 to build and debug
    return 0;
}
'@ | Set-Content -Path $mainFile -Encoding ASCII
    }

    # Placeholder tokens avoid fighting PowerShell over ${...} inside JSON.
    $tasks = @'
{
  "version": "2.0.0",
  "tasks": [
    {
      "type": "cppbuild",
      "label": "build active file",
      "command": "__GCC__",
      "args": [
        "-std=__STD__", "-Wall", "-Wextra", "-g",
        "${file}", "-o", "${fileDirname}\\__BSNAME__.exe"
      ],
      "options": { "cwd": "${fileDirname}" },
      "problemMatcher": ["$gcc"],
      "group": { "kind": "build", "isDefault": true }
    }
  ]
}
'@
    $tasks = $tasks.Replace('__GCC__', $gccJson).
                    Replace('__STD__', $Config.Standard).
                    Replace('__BSNAME__', '${fileBasenameNoExtension}')
    Write-IfAbsent -Path (Join-Path $vscodeDir 'tasks.json') -Content $tasks

    $launch = @'
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug active file",
      "type": "cppdbg",
      "request": "launch",
      "program": "${fileDirname}\\__BSNAME__.exe",
      "args": [],
      "stopAtEntry": false,
      "cwd": "${fileDirname}",
      "externalConsole": false,
      "MIMode": "gdb",
      "miDebuggerPath": "__GDB__",
      "preLaunchTask": "build active file"
    }
  ]
}
'@
    $launch = $launch.Replace('__GDB__', $gdbJson).
                      Replace('__BSNAME__', '${fileBasenameNoExtension}')
    Write-IfAbsent -Path (Join-Path $vscodeDir 'launch.json') -Content $launch

    $props = @'
{
  "version": 4,
  "configurations": [
    {
      "name": "Win32-GCC",
      "includePath": ["${workspaceFolder}/**"],
      "compilerPath": "__GCCFWD__",
      "cStandard": "c89",
      "cppStandard": "c++17",
      "intelliSenseMode": "windows-gcc-x64"
    }
  ]
}
'@
    $props = $props.Replace('__GCCFWD__', ($gccPath -replace '\\', '/'))
    Write-IfAbsent -Path (Join-Path $vscodeDir 'c_cpp_properties.json') -Content $props

    Write-Ok (T 'sc_ok' $Directory)
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

$Script:SelectedToolchains = @()
$Script:SelectedEditors    = @()

function Invoke-Bootstrap {
    # Before the banner, because the banner itself is localized.
    if (-not $LanguageWasPinned) { $Config.Language = Get-Language }

    Write-Banner
    Write-Host ("   " + (T 'detected' ([Environment]::OSVersion.Version)))

    if (-not (Test-IsAdmin)) { Write-Warn (T 'not_admin') }

    $Script:SelectedToolchains = Get-Toolchains
    $Script:SelectedEditors    = Get-Editors

    # Validate ids that came from the environment rather than the menu.
    foreach ($id in $Script:SelectedToolchains) {
        if ($id -notin $AllToolchains) { throw (T 'e_badpick' $id) }
    }
    foreach ($id in $Script:SelectedEditors) {
        if ($id -notin $AllEditors) { throw (T 'e_badpick' $id) }
    }
    if ($Script:SelectedToolchains.Count -eq 0 -and $Script:SelectedEditors.Count -eq 0) {
        throw (T 'e_nopick')
    }

    $total = $Script:SelectedToolchains.Count + 1
    if ($Script:SelectedEditors.Count -gt 0) { $total++ }
    if ($Config.ScaffoldDir)                 { $total++ }
    $n = 1

    foreach ($id in $Script:SelectedToolchains) {
        Write-Step $n $total (T 's_install_tc' (Get-ToolchainLabel $id)); $n++
        try { Install-Toolchain $id }
        catch { Write-Warn (T 'tc_failed' (Get-ToolchainLabel $id)); Write-Note $_.Exception.Message }
    }

    if ($Script:SelectedEditors.Count -gt 0) {
        Write-Step $n $total (T 's_editors'); $n++
        foreach ($id in $Script:SelectedEditors) {
            switch ($id) {
                'vscode' { Install-VSCode }
                'kate'   { Install-Kate }
                'vim'    { Install-Vim }
            }
        }
    }

    if ($Config.ScaffoldDir) {
        Write-Step $n $total (T 's_scaffold'); $n++
        New-Scaffold -Directory $Config.ScaffoldDir
    }

    Write-Step $n $total (T 's_verify')
    foreach ($id in $Script:SelectedToolchains) { Test-Toolchain $id }

    Write-Host ''
    Write-Host '  =============================================' -ForegroundColor Green
    Write-Host ("   " + (T 'done_title')) -ForegroundColor Green
    Write-Host '  =============================================' -ForegroundColor Green
    Write-Host ''
    Write-Host ("   " + (T 'summary'))
    Write-Host ''
    foreach ($tool in @('gcc', 'g++', 'gdb', 'mingw32-make', 'clangd',
                        'dotnet', 'rustc', 'cargo', 'go', 'python', 'pip',
                        'javac', 'java', 'code', 'kate', 'vim')) {
        $path = Resolve-Tool $tool
        if ($path) { Write-Host ('   {0,-14} {1}' -f $tool, $path) -ForegroundColor Gray }
    }
    Write-Host ''
    Write-Host ("   " + (T 'reopen')) -ForegroundColor Yellow
    Write-Host ''
}

try {
    Invoke-Bootstrap
}
catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    Write-Host ''
    Write-Host ("   " + (T 'resume1')) -ForegroundColor Yellow
    Write-Host ("   " + (T 'resume2')) -ForegroundColor Yellow
    Write-Host ''
    exit 1
}
