#Requires -Version 5.1
<#
    C/C++ Development Environment Bootstrapper for Windows
    ------------------------------------------------------
    Written for students of Universite Sorbonne Paris Nord (Paris 13) who need
    an ANSI C toolchain for their coursework, but nothing here is specific to
    that university - any student on any machine can run it.

    Installs, verifies, and wires up a complete C / C++ toolchain:

      * MSYS2 + MinGW-w64 UCRT64 GCC toolchain (gcc, g++, gdb, make)
      * GCC on the user PATH
      * Visual Studio Code and/or Kate, with cpptools and clangd
      * A verified test compile using ANSI C semantics with // comments

    Speaks English and French. The language follows your Windows display
    language and can be forced with CBOOT_LANG.

    Every step is skip-if-present, so re-running is safe and cheap.

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

        $env:CBOOT_LANG         = 'fr'      # en | fr (auto-detected)
        $env:CBOOT_PROFILE      = 'c'       # c | cpp | full  (skips the question)
        $env:CBOOT_EDITOR       = 'kate'    # vscode | kate | both | none
        $env:CBOOT_ASSUME_YES   = '1'       # accept every default, never prompt
        $env:CBOOT_STD          = 'gnu89'   # compiler standard for the verify step
        $env:CBOOT_MSYS2_ROOT   = 'C:\msys64'
        $env:CBOOT_SKIP_VSCODE  = '1'       # skip the VS Code step
        $env:CBOOT_SCAFFOLD_DIR = 'C:\dev\hello'  # also create a starter project
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

# Follow the Windows display language unless told otherwise. A French student
# on a French system should not have to know an environment variable exists.
function Get-DefaultLanguage {
    try {
        if ((Get-UICulture).TwoLetterISOLanguageName -eq 'fr') { return 'fr' }
        if ((Get-Culture).TwoLetterISOLanguageName   -eq 'fr') { return 'fr' }
    }
    catch { }
    return 'en'
}

$Config = @{
    Msys2Root   = Get-EnvOrDefault 'CBOOT_MSYS2_ROOT' 'C:\msys64'
    Standard    = Get-EnvOrDefault 'CBOOT_STD'        'gnu89'
    SkipVSCode  = (Get-EnvOrDefault 'CBOOT_SKIP_VSCODE' '0') -eq '1'
    ScaffoldDir = Get-EnvOrDefault 'CBOOT_SCAFFOLD_DIR' ''
    Profile     = Get-EnvOrDefault 'CBOOT_PROFILE' ''
    Editor      = Get-EnvOrDefault 'CBOOT_EDITOR' ''
    Language    = (Get-EnvOrDefault 'CBOOT_LANG' (Get-DefaultLanguage)).ToLower()
    AssumeYes   = (Get-EnvOrDefault 'CBOOT_ASSUME_YES' '0') -eq '1'
    MaxRetries  = 5
}

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

if ($Config.Profile -and ($Config.Profile.ToLower() -notin @('c', 'cpp', 'full'))) {
    throw "Unknown CBOOT_PROFILE='$($Config.Profile)' (expected c, cpp or full)"
}

if ($Config.Editor -and ($Config.Editor.ToLower() -notin @('vscode', 'kate', 'both', 'none'))) {
    throw "Unknown CBOOT_EDITOR='$($Config.Editor)' (expected vscode, kate, both or none)"
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

$BinDir = Join-Path $Config.Msys2Root "$SubsystemDir\bin"

# --------------------------------------------------------------------------
# Messages
#
# One entry per key, English and French side by side so they cannot drift
# apart. Values are format strings for the -f operator.
# --------------------------------------------------------------------------

$Messages = @{
    # -- banner / framing ---------------------------------------------------
    'title'          = @{ en = 'C / C++ Development Environment Installer';           fr = "Installateur d'environnement de développement C / C++" }
    'built_for'      = @{ en = 'Built for Universite Sorbonne Paris Nord (Paris 13)'; fr = "Conçu pour les étudiants de l'Université Sorbonne" }
    'built_for2'     = @{ en = 'students starting their ANSI C coursework.';          fr = 'Paris Nord (Paris 13) qui débutent en C ANSI.' }
    'not_affiliated' = @{ en = 'Not affiliated with the university -- usable by anyone.'; fr = "Sans lien avec l'université -- utilisable par tous." }
    'detected'       = @{ en = 'Detected: Windows {0}';                               fr = 'Détecté : Windows {0}' }

    # -- questions ----------------------------------------------------------
    'q_profile'      = @{ en = 'What do you need this machine set up for?';           fr = 'Pour quel usage voulez-vous configurer cette machine ?' }
    'q_profile_1'    = @{ en = '  1) C only        - ANSI C coursework (gcc, gdb, make)'; fr = '  1) C uniquement  - TP de C ANSI (gcc, gdb, make)' }
    'q_profile_2'    = @{ en = '  2) C and C++     - adds the g++ compiler';          fr = '  2) C et C++      - ajoute le compilateur g++' }
    'q_profile_3'    = @{ en = '  3) Full setup    - C, C++, and an editor';          fr = '  3) Complet       - C, C++ et un éditeur' }
    'q_choose_123'   = @{ en = 'Choose 1, 2 or 3';                                    fr = 'Choisissez 1, 2 ou 3' }
    'q_editor'       = @{ en = 'Which editor do you want?';                           fr = 'Quel éditeur voulez-vous ?' }
    'q_editor_1'     = @{ en = '  1) Visual Studio Code  - full IDE features, debugger, IntelliSense'; fr = '  1) Visual Studio Code  - IDE complet, débogueur, IntelliSense' }
    'q_editor_2'     = @{ en = '  2) Kate                - lightweight KDE editor, fast, simple';      fr = '  2) Kate                - éditeur KDE léger, rapide, simple' }
    'q_editor_3'     = @{ en = '  3) Both';                                           fr = '  3) Les deux' }
    'q_editor_4'     = @{ en = '  4) Neither             - I already have one';       fr = "  4) Aucun               - j'en ai déjà un" }
    'q_choose_1234'  = @{ en = 'Choose 1, 2, 3 or 4';                                 fr = 'Choisissez 1, 2, 3 ou 4' }
    'q_yn'           = @{ en = '{0} (y/n)';                                           fr = '{0} (o/n)' }
    'q_continue'     = @{ en = 'Continue anyway?';                                    fr = 'Continuer quand même ?' }

    # -- steps --------------------------------------------------------------
    's_check'        = @{ en = 'Checking for an existing GCC toolchain';              fr = "Recherche d'une chaîne d'outils GCC existante" }
    's_msys2'        = @{ en = 'Installing MSYS2';                                    fr = 'Installation de MSYS2' }
    's_toolchain'    = @{ en = 'Installing the MinGW-w64 GCC toolchain';              fr = "Installation de la chaîne d'outils MinGW-w64" }
    's_path'         = @{ en = 'Configuring PATH';                                    fr = 'Configuration du PATH' }
    's_vscode'       = @{ en = 'Installing Visual Studio Code';                       fr = 'Installation de Visual Studio Code' }
    's_kate'         = @{ en = 'Installing Kate';                                     fr = 'Installation de Kate' }
    's_scaffold'     = @{ en = 'Creating the starter project';                        fr = 'Création du projet de départ' }
    's_verifying'    = @{ en = '--- Verifying ---';                                   fr = '--- Vérification ---' }

    # -- environment --------------------------------------------------------
    'not_admin'      = @{ en = 'Not running as Administrator - installers may raise a UAC prompt.'; fr = "Pas de droits administrateur - une invite UAC peut apparaître." }
    'found'          = @{ en = 'Found: {0}';                                          fr = 'Trouvé : {0}' }
    'no_gcc'         = @{ en = 'No gcc on PATH - will install';                       fr = 'gcc absent du PATH - installation prévue' }
    'path_have'      = @{ en = 'Already on PATH: {0}';                                fr = 'Déjà dans le PATH : {0}' }
    'path_added'     = @{ en = 'Added to user PATH: {0}';                             fr = 'Ajouté au PATH utilisateur : {0}' }
    'path_long'      = @{ en = "User PATH is {0} chars; adding '{1}' risks truncation. Remove stale entries first."; fr = "Le PATH utilisateur fait {0} caracteres ; ajouter '{1}' risque de le tronquer. Supprimez d'abord les entrées obsoletes." }

    # -- MSYS2 / toolchain --------------------------------------------------
    'msys2_have'     = @{ en = 'MSYS2 already present at {0}';                        fr = 'MSYS2 est déjà présent dans {0}' }
    'msys2_ok'       = @{ en = 'MSYS2 installed at {0}';                              fr = 'MSYS2 installé dans {0}' }
    'msys2_none'     = @{ en = 'MSYS2 not found - installing';                        fr = 'MSYS2 introuvable - installation en cours' }
    'msys2_winget'   = @{ en = 'Installing via winget';                               fr = 'Installation via winget' }
    'msys2_fallback' = @{ en = 'Falling back to the official MSYS2 installer';        fr = "Bascule vers l'installateur officiel MSYS2" }
    'msys2_fail'     = @{ en = 'MSYS2 installation failed. Install it manually from https://www.msys2.org and re-run.'; fr = "Échec de l'installation de MSYS2. Installez-le depuis https://www.msys2.org puis relancez." }
    'sig_ok'         = @{ en = 'Installer signature valid';                           fr = "Signature de l'installateur valide" }
    'sig_by'         = @{ en = 'Signed by: {0}';                                      fr = 'Signé par : {0}' }
    'sig_bad'        = @{ en = "Refusing to run the MSYS2 installer: signature status is '{0}'. Download it yourself from https://www.msys2.org instead."; fr = "Refus d'executer l'installateur MSYS2 : statut de signature '{0}'. Téléchargez-le vous-même depuis https://www.msys2.org." }
    'sig_unexpected' = @{ en = 'That is not the signer this script expects for MSYS2.'; fr = "Ce n'est pas le signataire attendu pour MSYS2." }
    'sig_aborted'    = @{ en = 'Aborted at the signature check.';                     fr = 'Interrompu lors de la vérification de signature.' }
    'tc_have'        = @{ en = 'GCC toolchain already installed';                     fr = "Chaîne d'outils GCC déjà installée" }
    'tc_ok'          = @{ en = 'GCC toolchain installed';                             fr = "Chaîne d'outils GCC installée" }
    'tc_refresh'     = @{ en = 'Refreshing and upgrading packages';                   fr = 'Actualisation et mise à jour des paquets' }
    'tc_attempt'     = @{ en = 'Installing {0} (attempt {1}/{2})';                    fr = 'Installation de {0} (tentative {1}/{2})' }
    'tc_retry'       = @{ en = 'Attempt failed (usually a mirror timeout) - retrying'; fr = "Tentative échouée (souvent un miroir trop lent) - nouvelle tentative" }
    'tc_giveup'      = @{ en = 'Toolchain install failed after {0} attempts. Check your network and re-run.'; fr = "Échec de l'installation après {0} tentatives. Vérifiez votre réseau et relancez." }

    # -- editors ------------------------------------------------------------
    'vscode_have'    = @{ en = 'VS Code already installed';                           fr = 'VS Code est déjà installé' }
    'vscode_ok'      = @{ en = 'VS Code installed';                                   fr = 'VS Code installé' }
    'vscode_winget'  = @{ en = 'Installing VS Code via winget';                       fr = 'Installation de VS Code via winget' }
    'vscode_nowinget'= @{ en = 'winget unavailable - install VS Code manually from https://code.visualstudio.com'; fr = 'winget indisponible - installez VS Code depuis https://code.visualstudio.com' }
    'vscode_fail'    = @{ en = 'VS Code install did not complete - continuing without it'; fr = "L'installation de VS Code a échoué - on continue sans lui" }
    'ext_check'      = @{ en = 'Ensuring the C/C++ extension is present';             fr = "Vérification de l'extension C/C++" }
    'ext_have'       = @{ en = 'Extension ms-vscode.cpptools already installed';      fr = 'Extension ms-vscode.cpptools déjà installée' }
    'ext_ok'         = @{ en = 'Extension ms-vscode.cpptools installed';              fr = 'Extension ms-vscode.cpptools installée' }
    'kate_have'      = @{ en = 'Kate already installed ({0})';                        fr = 'Kate est déjà installé ({0})' }
    'kate_ok'        = @{ en = 'Kate installed';                                      fr = 'Kate installé' }
    'kate_winget'    = @{ en = 'Installing Kate via winget';                          fr = 'Installation de Kate via winget' }
    'kate_nowinget'  = @{ en = 'winget unavailable - install Kate manually from https://kate-editor.org'; fr = 'winget indisponible - installez Kate depuis https://kate-editor.org' }
    'kate_fail'      = @{ en = 'Kate install did not complete - continuing without it'; fr = "L'installation de Kate a échoué - on continue sans lui" }
    'clangd_have'    = @{ en = 'clangd already installed';                            fr = 'clangd est déjà installé' }
    'clangd_inst'    = @{ en = 'Installing clangd for Kate code completion';          fr = 'Installation de clangd pour la complétion dans Kate' }
    'clangd_ok'      = @{ en = 'clangd installed - enable the LSP Client plugin in Kate'; fr = 'clangd installé - activez le plugin LSP Client dans Kate' }
    'clangd_fail'    = @{ en = 'clangd install failed - Kate still works, just without completion'; fr = 'Échec de clangd - Kate fonctionne, mais sans complétion' }
    'skipped_env'    = @{ en = 'Skipped (CBOOT_SKIP_VSCODE=1)';                       fr = 'Ignoré (CBOOT_SKIP_VSCODE=1)' }

    # -- verification -------------------------------------------------------
    'v_nogcc'        = @{ en = 'gcc is still not resolvable from PATH.';              fr = "gcc reste introuvable dans le PATH." }
    'v_cfail'        = @{ en = 'Verification compile failed under -std={0}.';         fr = 'Échec de la compilation de vérification avec -std={0}.' }
    'v_badout'       = @{ en = 'Verification binary produced unexpected output: {0}'; fr = 'Le programme de vérification a produit une sortie inattendue : {0}' }
    'v_cok'          = @{ en = 'Compiled and ran a C program using -std={0}';         fr = 'Programme C compilé et exécuté avec -std={0}' }
    'v_comments'     = @{ en = 'Both /* */ and // comment styles accepted';           fr = 'Les commentaires /* */ et // sont tous deux acceptés' }
    'v_nogpp'        = @{ en = 'g++ not found - skipping the C++ check';              fr = 'g++ introuvable - vérification C++ ignorée' }
    'v_cppok'        = @{ en = 'C++ toolchain verified (-std=c++17)';                 fr = "Chaîne d'outils C++ vérifiée (-std=c++17)" }
    'v_cppfail'      = @{ en = 'C++ verification failed';                             fr = 'Échec de la vérification C++' }

    # -- scaffold -----------------------------------------------------------
    'sc_kept'        = @{ en = 'Kept existing {0}';                                   fr = 'Fichier {0} conservé' }
    'sc_ok'          = @{ en = 'Starter project created at {0}';                      fr = 'Projet de départ créé dans {0}' }

    # -- summary ------------------------------------------------------------
    'done_title'     = @{ en = 'Installation complete';                               fr = 'Installation terminée' }
    'reopen'         = @{ en = 'IMPORTANT: open a NEW terminal before using gcc.';    fr = "IMPORTANT : ouvrez un NOUVEAU terminal avant d'utiliser gcc." }
    'reopen2'        = @{ en = 'Existing windows still hold the old PATH.';           fr = "Les fenêtres déjà ouvertes gardent l'ancien PATH." }
    'compile_run'    = @{ en = 'Compile and run:';                                    fr = 'Compiler et exécuter :' }
    'resume1'        = @{ en = 'Re-run the installer to resume - completed steps are skipped'; fr = "Relancez l'installateur pour reprendre - les étapes terminées" }
    'resume2'        = @{ en = 'and partial downloads are reused from the pacman cache.'; fr = 'sont ignorées et les téléchargements partiels sont réutilisés.' }
    'cannot_prompt'  = @{ en = "Cannot prompt here - using default '{0}'";            fr = "Impossible de poser la question ici - valeur par défaut '{0}'" }
}

# Looks up a message in the active language and applies -f formatting.
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

function Write-Banner {
    Write-Host ''
    Write-Host '  ===========================================' -ForegroundColor Cyan
    Write-Host ("   " + (T 'title')) -ForegroundColor Cyan
    Write-Host '  ===========================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ("   " + (T 'built_for'))
    Write-Host ("   " + (T 'built_for2'))
    Write-Host ("   " + (T 'not_affiliated')) -ForegroundColor DarkGray
    Write-Host ''
}

function Write-Step {
    param([int]$Number, [int]$Total, [string]$Message)
    Write-Host ''
    Write-Host "[$Number/$Total] $Message" -ForegroundColor Cyan
}
function Write-Ok   { param([string]$M) Write-Host "      OK   $M" -ForegroundColor Green }
function Write-Note { param([string]$M) Write-Host "      ..   $M" -ForegroundColor DarkGray }
function Write-Warn { param([string]$M) Write-Host "      WARN $M" -ForegroundColor Yellow }
function Write-Fail { param([string]$M) Write-Host "      FAIL $M" -ForegroundColor Red }

# --------------------------------------------------------------------------
# Interaction
# --------------------------------------------------------------------------

# `irm | iex` still has a live console, so Read-Host works. It does not when
# the script runs from a scheduled task or CI, so degrade to the default.
function Test-CanPrompt {
    if ($Config.AssumeYes) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }

    # UserInteractive stays true under `powershell -NonInteractive` and in CI,
    # where Read-Host either throws or reads redirected stdin. Checking for a
    # redirected input stream is what actually distinguishes the two.
    try {
        if ([Console]::IsInputRedirected) { return $false }
    }
    catch {
        return $false
    }
    return $true
}

function Read-Answer {
    param([string]$Question, [string]$Default)

    if (-not (Test-CanPrompt)) {
        Write-Host "      $Question [auto: $Default]" -ForegroundColor DarkGray
        return $Default
    }
    # Even with the checks above, some hosts refuse to prompt. Falling back to
    # the default beats aborting the whole install from the outer catch block.
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
    param([string]$Question)
    $default = if ($Config.Language -eq 'fr') { 'o' } else { 'y' }
    return (Read-Answer (T 'q_yn' $Question) $default) -match '^[YyOo]'
}

# Asks what the machine is being set up for and maps it onto the feature flags.
function Get-Profile {
    if ($Config.Profile) { return $Config.Profile.ToLower() }

    Write-Host ("   " + (T 'q_profile'))
    Write-Host ''
    Write-Host ("   " + (T 'q_profile_1'))
    Write-Host ("   " + (T 'q_profile_2'))
    Write-Host ("   " + (T 'q_profile_3'))
    Write-Host ''

    switch (Read-Answer (T 'q_choose_123') '3') {
        '1'     { return 'c' }
        '2'     { return 'cpp' }
        default { return 'full' }
    }
}

# Which editor(s) to set up. Only asked when the chosen profile includes one.
function Get-Editor {
    if ($Config.Editor) { return $Config.Editor.ToLower() }
    if ($Config.SkipVSCode) { return 'none' }

    Write-Host ''
    Write-Host ("   " + (T 'q_editor'))
    Write-Host ''
    Write-Host ("   " + (T 'q_editor_1'))
    Write-Host ("   " + (T 'q_editor_2'))
    Write-Host ("   " + (T 'q_editor_3'))
    Write-Host ("   " + (T 'q_editor_4'))
    Write-Host ''

    switch (Read-Answer (T 'q_choose_1234') '1') {
        '2'     { return 'kate' }
        '3'     { return 'both' }
        '4'     { return 'none' }
        default { return 'vscode' }
    }
}

# --------------------------------------------------------------------------
# Environment helpers
# --------------------------------------------------------------------------

# A freshly installed program is invisible to this process until the registry
# PATH is re-read, because the environment block was copied at process start.
# Rebuild it after every installation step.
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

# --------------------------------------------------------------------------
# MSYS2 / pacman
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
    finally {
        $env:MSYSTEM = $previous
    }
}

# Refuses to run a downloaded binary whose Authenticode signature is missing or
# broken. If the signature is valid but from an unexpected signer, the signer is
# shown and confirmation is required, because MSYS2's signing identity can
# legitimately change between releases and hardcoding one would break installs.
function Assert-TrustedInstaller {
    param([string]$Path)

    $signature = Get-AuthenticodeSignature -FilePath $Path

    if ($signature.Status -ne 'Valid') {
        throw (T 'sig_bad' $signature.Status)
    }

    $signer = $signature.SignerCertificate.Subject
    Write-Ok (T 'sig_ok')
    Write-Note (T 'sig_by' $signer)

    if ($signer -notmatch 'MSYS2|Christoph Reiter') {
        Write-Warn (T 'sig_unexpected')
        if (-not (Read-Confirm (T 'q_continue'))) {
            throw (T 'sig_aborted')
        }
    }
}

function Install-Msys2 {
    if (Test-Path (Join-Path $Config.Msys2Root 'usr\bin\bash.exe')) {
        Write-Ok (T 'msys2_have' $Config.Msys2Root)
        return
    }

    Write-Note (T 'msys2_none')

    $winget = Resolve-Tool 'winget'
    if ($winget) {
        Write-Note (T 'msys2_winget')
        & $winget install --id MSYS2.MSYS2 -e --source winget `
            --accept-package-agreements --accept-source-agreements 2>&1 |
            ForEach-Object { Write-Note $_ }
        Sync-ProcessPath
    }

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

            # Qt Installer Framework silent-install flags; root wants forward slashes.
            $root = $Config.Msys2Root -replace '\\', '/'
            Start-Process -FilePath $temp -Wait -ArgumentList @(
                'in', '--confirm-command', '--accept-messages', '--root', $root
            )
        }
        finally {
            Remove-Item $temp -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path (Join-Path $Config.Msys2Root 'usr\bin\bash.exe'))) {
        throw (T 'msys2_fail')
    }
    Write-Ok (T 'msys2_ok' $Config.Msys2Root)
}

function Install-Toolchain {
    if (Test-Path (Join-Path $BinDir 'gcc.exe')) {
        Write-Ok (T 'tc_have')
        return
    }

    # -Syu, not -Sy. MSYS2 documents partial upgrades as unsupported: syncing
    # the database without upgrading can install packages built against newer
    # libraries than the ones on disk. Matters most when pointed at an older
    # pre-existing MSYS2 rather than a fresh one.
    Write-Note (T 'tc_refresh')
    Invoke-Pacman '-Syu --noconfirm' | Out-Null

    # MSYS2 mirrors time out fairly often mid-transaction. Completed package
    # downloads stay in the pacman cache, so each retry resumes rather than
    # restarting - a handful of attempts reliably gets there.
    $installed = $false
    for ($attempt = 1; $attempt -le $Config.MaxRetries; $attempt++) {
        Write-Note (T 'tc_attempt' $PackageGroup $attempt $Config.MaxRetries)
        $code = Invoke-Pacman "-S --needed --noconfirm $PackageGroup"

        if ($code -eq 0 -and (Test-Path (Join-Path $BinDir 'gcc.exe'))) {
            $installed = $true
            break
        }
        Write-Warn (T 'tc_retry')
    }

    if (-not $installed) {
        throw (T 'tc_giveup' $Config.MaxRetries)
    }
    Write-Ok (T 'tc_ok')
}

# --------------------------------------------------------------------------
# Visual Studio Code
# --------------------------------------------------------------------------

function Find-VSCode {
    $candidates = @(
        (Resolve-Tool 'code'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:ProgramFiles  'Microsoft VS Code\bin\code.cmd')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

function Install-VSCode {
    if ($Config.SkipVSCode) {
        Write-Note (T 'skipped_env')
        return $null
    }

    $code = Find-VSCode
    if ($code) {
        Write-Ok (T 'vscode_have')
    }
    else {
        $winget = Resolve-Tool 'winget'
        if (-not $winget) {
            Write-Warn (T 'vscode_nowinget')
            return $null
        }

        Write-Note (T 'vscode_winget')
        & $winget install --id Microsoft.VisualStudioCode -e --source winget `
            --scope user --accept-package-agreements --accept-source-agreements 2>&1 |
            ForEach-Object { Write-Note $_ }

        Sync-ProcessPath
        $code = Find-VSCode
        if (-not $code) {
            Write-Warn (T 'vscode_fail')
            return $null
        }
        Write-Ok (T 'vscode_ok')
    }

    # The C/C++ extension supplies IntelliSense and the cppdbg debugger that
    # the generated launch.json depends on.
    Write-Note (T 'ext_check')
    $existing = & $code --list-extensions 2>$null
    if ($existing -contains 'ms-vscode.cpptools') {
        Write-Ok (T 'ext_have')
    }
    else {
        & $code --install-extension ms-vscode.cpptools --force 2>&1 |
            ForEach-Object { Write-Note $_ }
        Write-Ok (T 'ext_ok')
    }

    return $code
}

# --------------------------------------------------------------------------
# Kate
# --------------------------------------------------------------------------

function Find-Kate {
    $candidates = @(
        (Resolve-Tool 'kate'),
        (Join-Path $env:ProgramFiles          'Kate\bin\kate.exe'),
        (Join-Path ${env:ProgramFiles(x86)}   'Kate\bin\kate.exe'),
        (Join-Path $env:LOCALAPPDATA          'Programs\Kate\bin\kate.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

function Install-Kate {
    $kate = Find-Kate
    if ($kate) {
        Write-Ok (T 'kate_have' $kate)
        return $kate
    }

    $winget = Resolve-Tool 'winget'
    if (-not $winget) {
        Write-Warn (T 'kate_nowinget')
        return $null
    }

    Write-Note (T 'kate_winget')
    & $winget install --id KDE.Kate -e --source winget `
        --accept-package-agreements --accept-source-agreements 2>&1 |
        ForEach-Object { Write-Note $_ }

    Sync-ProcessPath
    $kate = Find-Kate
    if (-not $kate) {
        Write-Warn (T 'kate_fail')
        return $null
    }
    Write-Ok (T 'kate_ok')

    # Kate has no built-in C parser. Its LSP plugin drives clangd, so install
    # clangd too, otherwise Kate is only a syntax-highlighting text editor.
    Install-Clangd
    return $kate
}

# Best-effort: Kate is perfectly usable without it, so never fail the install.
function Install-Clangd {
    if (Resolve-Tool 'clangd') {
        Write-Ok (T 'clangd_have')
        return
    }

    Write-Note (T 'clangd_inst')
    $code = Invoke-Pacman '-S --needed --noconfirm mingw-w64-ucrt-x86_64-clang-tools-extra'

    Sync-ProcessPath
    if ($code -eq 0 -and (Resolve-Tool 'clangd')) {
        Write-Ok (T 'clangd_ok')
    }
    else {
        Write-Warn (T 'clangd_fail')
    }
}

# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------

function Test-Toolchain {
    param([bool]$IncludeCpp)

    Sync-ProcessPath

    $gcc = Resolve-Tool 'gcc'
    if (-not $gcc) { throw (T 'v_nogcc') }

    $work = Join-Path $env:TEMP ('cboot-verify-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    try {
        # Deliberately mixes ANSI block comments with // line comments, so a
        # pass proves the configured standard accepts both styles.
        $source = Join-Path $work 'verify.c'
        @'
#include <stdio.h>

/* ANSI C style block comment */
int main(void)
{
    int value = 42;   // line comment - rejected by strict c89
    printf("TOOLCHAIN_OK %d\n", value);
    return 0;
}
'@ | Set-Content -Path $source -Encoding ASCII

        $exe = Join-Path $work 'verify.exe'
        & $gcc "-std=$($Config.Standard)" -Wall -Wextra $source -o $exe 2>&1 |
            ForEach-Object { Write-Note $_ }

        if (-not (Test-Path $exe)) {
            throw (T 'v_cfail' $Config.Standard)
        }

        $output = & $exe
        if ($output -notmatch 'TOOLCHAIN_OK 42') {
            throw (T 'v_badout' $output)
        }

        Write-Ok (T 'v_cok' $Config.Standard)
        Write-Ok (T 'v_comments')

        if ($IncludeCpp) {
            $gpp = Resolve-Tool 'g++'
            if (-not $gpp) {
                Write-Warn (T 'v_nogpp')
                return
            }

            $cppSource = Join-Path $work 'verify.cpp'
            @'
#include <iostream>
#include <vector>
int main() {
    std::vector<int> v{1, 2, 3};
    for (int i : v) std::cout << i;
    std::cout << " CPP_OK\n";
}
'@ | Set-Content -Path $cppSource -Encoding ASCII

            $cppExe = Join-Path $work 'verifycpp.exe'
            & $gpp -std=c++17 $cppSource -o $cppExe 2>&1 | ForEach-Object { Write-Note $_ }

            if ((Test-Path $cppExe) -and ((& $cppExe) -match 'CPP_OK')) {
                Write-Ok (T 'v_cppok')
            }
            else {
                Write-Warn (T 'v_cppfail')
            }
        }
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
# Optional starter project
# --------------------------------------------------------------------------

# Never overwrite. CBOOT_SCAFFOLD_DIR is just a path, so it is easy to aim at a
# real project by accident; silently replacing a tuned launch.json would destroy
# the student's work.
function Write-IfAbsent {
    param([string]$Path, [string]$Content)

    if (Test-Path $Path) {
        Write-Note (T 'sc_kept' (Split-Path $Path -Leaf))
        return
    }
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
        "-std=__STD__",
        "-Wall",
        "-Wextra",
        "-g",
        "${file}",
        "-o",
        "${fileDirname}\\__BSNAME__.exe"
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

function Invoke-Bootstrap {
    Write-Banner

    Write-Host ("   " + (T 'detected' ([Environment]::OSVersion.Version)))
    Write-Host ''

    $setupProfile = Get-Profile
    $includeCpp   = $setupProfile -in @('cpp', 'full')

    $editor = 'none'
    if ($setupProfile -eq 'full') { $editor = Get-Editor }
    $wantVSCode = $editor -in @('vscode', 'both')
    $wantKate   = $editor -in @('kate',   'both')

    # The MSYS2 toolchain group ships gcc and g++ as one unit, so the profile
    # controls what gets verified and which editors are installed, not which
    # compilers land on disk.
    $total = 4
    if ($wantVSCode)          { $total++ }
    if ($wantKate)            { $total++ }
    if ($Config.ScaffoldDir)  { $total++ }
    $stepNumber = 1

    if (-not (Test-IsAdmin)) {
        Write-Warn (T 'not_admin')
    }

    Write-Step $stepNumber $total (T 's_check'); $stepNumber++
    Sync-ProcessPath
    $existingGcc = Resolve-Tool 'gcc'
    if ($existingGcc) {
        Write-Ok (T 'found' $existingGcc)
        Write-Ok (& $existingGcc --version | Select-Object -First 1)
    }
    else {
        Write-Note (T 'no_gcc')
    }

    Write-Step $stepNumber $total (T 's_msys2'); $stepNumber++
    Install-Msys2

    Write-Step $stepNumber $total (T 's_toolchain'); $stepNumber++
    Install-Toolchain

    Write-Step $stepNumber $total (T 's_path'); $stepNumber++
    Add-ToUserPath -Directory $BinDir

    $code = $null
    if ($wantVSCode) {
        Write-Step $stepNumber $total (T 's_vscode'); $stepNumber++
        $code = Install-VSCode
    }

    $kate = $null
    if ($wantKate) {
        Write-Step $stepNumber $total (T 's_kate'); $stepNumber++
        $kate = Install-Kate
    }

    if ($Config.ScaffoldDir) {
        Write-Step $stepNumber $total (T 's_scaffold'); $stepNumber++
        New-Scaffold -Directory $Config.ScaffoldDir
    }

    Write-Host ''
    Write-Host ("  " + (T 's_verifying')) -ForegroundColor Cyan
    Test-Toolchain -IncludeCpp $includeCpp

    Write-Host ''
    Write-Host '  ===========================================' -ForegroundColor Green
    Write-Host ("   " + (T 'done_title')) -ForegroundColor Green
    Write-Host '  ===========================================' -ForegroundColor Green
    Write-Host ''

    foreach ($tool in @('gcc', 'g++', 'gdb', 'mingw32-make')) {
        $path = Resolve-Tool $tool
        if ($path) { Write-Host ('   {0,-14} {1}' -f $tool, $path) -ForegroundColor Gray }
        else       { Write-Host ('   {0,-14} MISSING' -f $tool) -ForegroundColor Red }
    }
    if (Resolve-Tool 'clangd') {
        Write-Host ('   {0,-14} {1}' -f 'clangd', (Resolve-Tool 'clangd')) -ForegroundColor Gray
    }
    if ($code) { Write-Host ('   {0,-14} {1}' -f 'vs code', $code) -ForegroundColor Gray }
    if ($kate) { Write-Host ('   {0,-14} {1}' -f 'kate',    $kate) -ForegroundColor Gray }

    Write-Host ''
    Write-Host ("   " + (T 'reopen'))  -ForegroundColor Yellow
    Write-Host ("   " + (T 'reopen2')) -ForegroundColor Yellow
    Write-Host ''
    Write-Host ("   " + (T 'compile_run')) -ForegroundColor Cyan
    Write-Host ('     gcc -std={0} -Wall hello.c -o hello.exe' -f $Config.Standard) -ForegroundColor White
    Write-Host '     hello.exe' -ForegroundColor White
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
