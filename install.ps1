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
      * Visual Studio Code and/or Kate, with C/C++ support
      * A verified test compile using ANSI C semantics with // comments

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

        $env:CBOOT_PROFILE      = 'c'       # c | cpp | full  (skips the question)
        $env:CBOOT_EDITOR       = 'kate'    # vscode | kate | both | none
        $env:CBOOT_ASSUME_YES   = '1'       # accept every default, never prompt
        $env:CBOOT_STD          = 'gnu89'   # compiler standard for the verify step
        $env:CBOOT_MSYS2_ROOT   = 'C:\msys64'
        $env:CBOOT_SKIP_VSCODE  = '1'       # skip the VS Code step
        $env:CBOOT_SCAFFOLD_DIR = 'C:\dev\hello'  # also create a starter project
#>

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

function Get-EnvOrDefault {
    param([string]$Name, [string]$Default)
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

$Config = @{
    Msys2Root   = Get-EnvOrDefault 'CBOOT_MSYS2_ROOT' 'C:\msys64'
    Standard    = Get-EnvOrDefault 'CBOOT_STD'        'gnu89'
    SkipVSCode  = (Get-EnvOrDefault 'CBOOT_SKIP_VSCODE' '0') -eq '1'
    ScaffoldDir = Get-EnvOrDefault 'CBOOT_SCAFFOLD_DIR' ''
    Profile     = Get-EnvOrDefault 'CBOOT_PROFILE' ''
    Editor      = Get-EnvOrDefault 'CBOOT_EDITOR' ''
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
# Output helpers (ASCII only - a fresh console may not be UTF-8)
# --------------------------------------------------------------------------

function Write-Banner {
    Write-Host ''
    Write-Host '  ===========================================' -ForegroundColor Cyan
    Write-Host '   C / C++ Development Environment Installer' -ForegroundColor Cyan
    Write-Host '  ===========================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '   Built for Universite Sorbonne Paris Nord (Paris 13)'
    Write-Host '   students starting their ANSI C coursework.'
    Write-Host '   Not affiliated with the university -- usable by anyone.' -ForegroundColor DarkGray
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

    # UserInteractive stays true under `powershell -NonInteractive` and in CI,
    # where Read-Host either throws or reads redirected stdin. Checking for a
    # redirected input stream is what actually distinguishes the two.
    try {
        if ([Console]::IsInputRedirected) { return $false }
    }
    catch {
        # No console attached at all (e.g. hosted runspace).
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
        Write-Note "Cannot prompt here - using default '$Default'"
        return $Default
    }
    if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
    return $reply.Trim()
}

function Read-Confirm {
    param([string]$Question)
    return (Read-Answer "$Question (y/n)" 'y') -match '^[Yy]'
}

# Asks what the machine is being set up for and maps it onto the feature flags.
function Get-Profile {
    if ($Config.Profile) { return $Config.Profile.ToLower() }

    Write-Host '   What do you need this machine set up for?'
    Write-Host ''
    Write-Host '     1) C only        - ANSI C coursework (gcc, gdb, make)'
    Write-Host '     2) C and C++     - adds the g++ compiler'
    Write-Host '     3) Full setup    - C, C++, and an editor'
    Write-Host ''

    switch (Read-Answer 'Choose 1, 2 or 3' '3') {
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
    Write-Host '   Which editor do you want?'
    Write-Host ''
    Write-Host '     1) Visual Studio Code  - full IDE features, debugger, IntelliSense'
    Write-Host '     2) Kate                - lightweight KDE editor, fast, simple'
    Write-Host '     3) Both'
    Write-Host '     4) Neither             - I already have one'
    Write-Host ''

    switch (Read-Answer 'Choose 1, 2, 3 or 4' '1') {
        '2'     { return 'kate' }
        '3'     { return 'both' }
        '4'     { return 'none' }
        default { return 'vscode' }
    }
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
            Write-Ok "Already on PATH: $Directory"
            return
        }
    }

    $updated = ($current.TrimEnd(';') + ';' + $Directory).TrimStart(';')

    # The user PATH is stored as REG_EXPAND_SZ and silently truncates past
    # ~2047 characters, which would destroy existing entries. Refuse instead.
    if ($updated.Length -gt 1900) {
        throw "User PATH is $($updated.Length) chars; adding '$Directory' risks truncation. Remove stale entries first."
    }

    [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
    Sync-ProcessPath
    Write-Ok "Added to user PATH: $Directory"
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
        throw ("Refusing to run the MSYS2 installer: signature status is " +
               "'$($signature.Status)'. Download it yourself from https://www.msys2.org instead.")
    }

    $signer = $signature.SignerCertificate.Subject
    Write-Ok "Installer signature valid"
    Write-Note "Signed by: $signer"

    if ($signer -notmatch 'MSYS2|Christoph Reiter') {
        Write-Warn 'That is not the signer this script expects for MSYS2.'
        if (-not (Read-Confirm "Continue anyway?")) {
            throw 'Aborted at the signature check.'
        }
    }
}

function Install-Msys2 {
    if (Test-Path (Join-Path $Config.Msys2Root 'usr\bin\bash.exe')) {
        Write-Ok "MSYS2 already present at $($Config.Msys2Root)"
        return
    }

    Write-Note 'MSYS2 not found - installing'

    $winget = Resolve-Tool 'winget'
    if ($winget) {
        Write-Note 'Installing via winget'
        & $winget install --id MSYS2.MSYS2 -e --source winget `
            --accept-package-agreements --accept-source-agreements 2>&1 |
            ForEach-Object { Write-Note $_ }
        Sync-ProcessPath
    }

    if (-not (Test-Path (Join-Path $Config.Msys2Root 'usr\bin\bash.exe'))) {
        Write-Note 'Falling back to the official MSYS2 installer'

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
        throw 'MSYS2 installation failed. Install it manually from https://www.msys2.org and re-run.'
    }
    Write-Ok "MSYS2 installed at $($Config.Msys2Root)"
}

function Install-Toolchain {
    if (Test-Path (Join-Path $BinDir 'gcc.exe')) {
        Write-Ok 'GCC toolchain already installed'
        return
    }

    # -Syu, not -Sy. MSYS2 documents partial upgrades as unsupported: syncing
    # the database without upgrading can install packages built against newer
    # libraries than the ones on disk. Matters most when pointed at an older
    # pre-existing MSYS2 rather than a fresh one.
    Write-Note 'Refreshing and upgrading packages'
    Invoke-Pacman '-Syu --noconfirm' | Out-Null

    # MSYS2 mirrors time out fairly often mid-transaction. Completed package
    # downloads stay in the pacman cache, so each retry resumes rather than
    # restarting - a handful of attempts reliably gets there.
    $installed = $false
    for ($attempt = 1; $attempt -le $Config.MaxRetries; $attempt++) {
        Write-Note "Installing $PackageGroup (attempt $attempt/$($Config.MaxRetries))"
        $code = Invoke-Pacman "-S --needed --noconfirm $PackageGroup"

        if ($code -eq 0 -and (Test-Path (Join-Path $BinDir 'gcc.exe'))) {
            $installed = $true
            break
        }
        Write-Warn 'Attempt failed (usually a mirror timeout) - retrying'
    }

    if (-not $installed) {
        throw "Toolchain install failed after $($Config.MaxRetries) attempts. Check your network and re-run."
    }
    Write-Ok 'GCC toolchain installed'
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
        Write-Note 'Skipped (CBOOT_SKIP_VSCODE=1)'
        return $null
    }

    $code = Find-VSCode
    if ($code) {
        Write-Ok 'VS Code already installed'
    }
    else {
        $winget = Resolve-Tool 'winget'
        if (-not $winget) {
            Write-Warn 'winget unavailable - install VS Code manually from https://code.visualstudio.com'
            return $null
        }

        Write-Note 'Installing VS Code via winget'
        & $winget install --id Microsoft.VisualStudioCode -e --source winget `
            --scope user --accept-package-agreements --accept-source-agreements 2>&1 |
            ForEach-Object { Write-Note $_ }

        Sync-ProcessPath
        $code = Find-VSCode
        if (-not $code) {
            Write-Warn 'VS Code install did not complete - continuing without it'
            return $null
        }
        Write-Ok 'VS Code installed'
    }

    # The C/C++ extension supplies IntelliSense and the cppdbg debugger that
    # the generated launch.json depends on.
    Write-Note 'Ensuring the C/C++ extension is present'
    $existing = & $code --list-extensions 2>$null
    if ($existing -contains 'ms-vscode.cpptools') {
        Write-Ok 'Extension ms-vscode.cpptools already installed'
    }
    else {
        & $code --install-extension ms-vscode.cpptools --force 2>&1 |
            ForEach-Object { Write-Note $_ }
        Write-Ok 'Extension ms-vscode.cpptools installed'
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
        Write-Ok "Kate already installed ($kate)"
        return $kate
    }

    $winget = Resolve-Tool 'winget'
    if (-not $winget) {
        Write-Warn 'winget unavailable - install Kate manually from https://kate-editor.org'
        return $null
    }

    Write-Note 'Installing Kate via winget'
    & $winget install --id KDE.Kate -e --source winget `
        --accept-package-agreements --accept-source-agreements 2>&1 |
        ForEach-Object { Write-Note $_ }

    Sync-ProcessPath
    $kate = Find-Kate
    if (-not $kate) {
        Write-Warn 'Kate install did not complete - continuing without it'
        return $null
    }
    Write-Ok 'Kate installed'

    # Kate has no built-in C parser. Its LSP plugin drives clangd, so install
    # clangd too, otherwise Kate is only a syntax-highlighting text editor.
    Install-Clangd
    return $kate
}

# Best-effort: Kate is perfectly usable without it, so never fail the install.
function Install-Clangd {
    if (Resolve-Tool 'clangd') {
        Write-Ok 'clangd already installed'
        return
    }

    Write-Note 'Installing clangd for Kate code completion'
    $code = Invoke-Pacman '-S --needed --noconfirm mingw-w64-ucrt-x86_64-clang-tools-extra'

    Sync-ProcessPath
    if ($code -eq 0 -and (Resolve-Tool 'clangd')) {
        Write-Ok 'clangd installed - enable the LSP Client plugin in Kate'
    }
    else {
        Write-Warn 'clangd install failed - Kate still works, just without completion'
    }
}

# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------

function Test-Toolchain {
    param([bool]$IncludeCpp)

    Sync-ProcessPath

    $gcc = Resolve-Tool 'gcc'
    if (-not $gcc) { throw 'gcc is still not resolvable from PATH.' }

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
            throw "Verification compile failed under -std=$($Config.Standard)."
        }

        $output = & $exe
        if ($output -notmatch 'TOOLCHAIN_OK 42') {
            throw "Verification binary produced unexpected output: $output"
        }

        Write-Ok "Compiled and ran a C program using -std=$($Config.Standard)"
        Write-Ok 'Both /* */ and // comment styles accepted'

        if ($IncludeCpp) {
            $gpp = Resolve-Tool 'g++'
            if (-not $gpp) {
                Write-Warn 'g++ not found - skipping the C++ check'
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
                Write-Ok 'C++ toolchain verified (-std=c++17)'
            }
            else {
                Write-Warn 'C++ verification failed'
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
        Write-Note "Kept existing $(Split-Path $Path -Leaf)"
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

    Write-Ok "Starter project created at $Directory"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

function Invoke-Bootstrap {
    Write-Banner

    Write-Host "   Detected: Windows $([Environment]::OSVersion.Version)"
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
        Write-Warn 'Not running as Administrator - installers may raise a UAC prompt.'
    }

    Write-Step $stepNumber $total 'Checking for an existing GCC toolchain'; $stepNumber++
    Sync-ProcessPath
    $existingGcc = Resolve-Tool 'gcc'
    if ($existingGcc) {
        Write-Ok "Found: $existingGcc"
        Write-Ok (& $existingGcc --version | Select-Object -First 1)
    }
    else {
        Write-Note 'No gcc on PATH - will install'
    }

    Write-Step $stepNumber $total 'Installing MSYS2'; $stepNumber++
    Install-Msys2

    Write-Step $stepNumber $total 'Installing the MinGW-w64 GCC toolchain'; $stepNumber++
    Install-Toolchain

    Write-Step $stepNumber $total 'Configuring PATH'; $stepNumber++
    Add-ToUserPath -Directory $BinDir

    $code = $null
    if ($wantVSCode) {
        Write-Step $stepNumber $total 'Installing Visual Studio Code'; $stepNumber++
        $code = Install-VSCode
    }

    $kate = $null
    if ($wantKate) {
        Write-Step $stepNumber $total 'Installing Kate'; $stepNumber++
        $kate = Install-Kate
    }

    if ($Config.ScaffoldDir) {
        Write-Step $stepNumber $total 'Creating the starter project'; $stepNumber++
        New-Scaffold -Directory $Config.ScaffoldDir
    }

    Write-Host ''
    Write-Host '  --- Verifying ---' -ForegroundColor Cyan
    Test-Toolchain -IncludeCpp $includeCpp

    Write-Host ''
    Write-Host '  ===========================================' -ForegroundColor Green
    Write-Host '   Installation complete' -ForegroundColor Green
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
    Write-Host '   IMPORTANT: open a NEW terminal before using gcc.' -ForegroundColor Yellow
    Write-Host '   Existing windows still hold the old PATH.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   Compile and run:' -ForegroundColor Cyan
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
    Write-Host '   Re-run the installer to resume - completed steps are skipped' -ForegroundColor Yellow
    Write-Host '   and partial downloads are reused from the pacman cache.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}
