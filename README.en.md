# cready

**English** · [Français](README.md)

> This project is written for French students, so **French is the default**.
> Everything here works identically in English: pick `2) English` at the first prompt,
> or run it with `CBOOT_LANG=en`.

One command that takes a blank machine to a working, **verified** C and C++ setup.

I wrote this for **Université Sorbonne Paris Nord (Paris 13)** students starting their
ANSI C coursework, because setting up a compiler on Windows is the first thing that stops
people, and because the assignments are graded against ANSI C while everyone still wants
`//` comments.

It is not affiliated with or endorsed by the university, and there is nothing Paris
13-specific in the code. **Any student, at any school, on any machine, can run it.**

---

## Install

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/xelasleepi/cready/main/install.ps1 | iex
```

### Linux, WSL, or macOS

```bash
curl -fsSL https://raw.githubusercontent.com/xelasleepi/cready/main/install.sh | bash
```

The script asks what you need, installs only that, and then **proves it works** by
compiling and running a real program before it claims success.

**It speaks French and English.** French is the default, and the first thing it asks is
which language you want:

```
   +---------------------------------------+
   |   Langue  /  Language                 |
   +---------------------------------------+

     1) Francais   (par defaut / default)
     2) English
```

Skip the question with `CBOOT_LANG=en`.

```
   What do you need this machine set up for?

     1) C only        - ANSI C coursework (gcc, gdb, make)
     2) C and C++     - adds the g++ compiler
     3) Full setup    - C, C++, and an editor

   Which editor do you want?

     1) Visual Studio Code  - full IDE features, debugger, IntelliSense
     2) Kate                - lightweight KDE editor, fast, simple
     3) Both
     4) Neither             - I already have one
```

---

## What you get

| | Windows | Linux / WSL / macOS |
|---|---|---|
| Compiler | MinGW-w64 GCC via MSYS2 (UCRT64) | distro GCC |
| Also installed | `g++`, `gdb`, `mingw32-make` | `g++`, `gdb`, `make`, `valgrind` |
| PATH | `C:\msys64\ucrt64\bin` added to **user** PATH | already on PATH |
| Editor | VS Code and/or Kate | VS Code and/or Kate |
| Editor extras | `ms-vscode.cpptools`, `clangd` for Kate | `ms-vscode.cpptools`, `clangd` for Kate |
| Verified | compiles **and runs** a test program | compiles **and runs** a test program |

### Which editor?

**VS Code** is the safe default: IntelliSense, a real debugger, and the generated
`launch.json` means F5 just builds and runs your program.

**Kate** is worth picking if VS Code feels heavy or your machine is old. It starts
instantly and stays out of your way. It has no built-in C support, so the installer also
sets up `clangd` alongside it — after installing, enable **Settings → Plugins → LSP Client**
in Kate and you get completion and error squiggles.

Picking "Both" installs both and lets you decide later.

Every step is skip-if-present. Re-running is safe, fast, and is also the supported way
to **resume a failed install**: finished work is detected, and partial downloads are
reused from the package cache.

---

## The ANSI C + `//` comments problem

Strict ANSI C (C89/C90) does not allow `//` line comments. If your course requires ANSI C
but you want `//`, the flag you want is **`-std=gnu89`**: C89 semantics, with `//` accepted.

Measured on GCC 16.2.0:

| Flag | `//` comments | Result |
|---|---|---|
| `-std=c89 -pedantic` | `error: C++ style comments are not allowed in ISO C90` | **fails to build** |
| `-std=gnu89` | accepted silently | **C89 + `//`**, the default here |
| `-std=gnu89 -pedantic` | warning only | builds, warns |
| `-std=c99` | fully legal | builds clean |

So:

```bash
gcc -std=gnu89 -Wall -Wextra main.c -o main
```

Pick a different one any time with `CBOOT_STD` (see below).

---

## Running your program

This trips up almost everyone coming from Linux.

| Shell | Command |
|---|---|
| **cmd** | `main.exe` or `.\main.exe`. `./main` does **not** work |
| **PowerShell** | `.\main.exe` (the `.\` is required) |
| **Git Bash / WSL / Linux** | `./main` |

`cmd` treats `/` as the option character, so `./main` fails with `'.' is not recognized`.
On Windows GCC also produces `.exe`, and with no `-o` the default is **`a.exe`**, not `a.out`.

---

## Options

Set these before running to skip the questions. Useful for lab machines and scripted setups.

| Variable | Does what | Default |
|---|---|---|
| `CBOOT_LANG` | `fr` or `en` (skips the language question) | `fr` |
| `CBOOT_PROFILE` | `c`, `cpp`, or `full` (skips the prompt) | *asks* |
| `CBOOT_EDITOR` | `vscode`, `kate`, `both`, or `none` | *asks* |
| `CBOOT_ASSUME_YES` | `1` = never prompt, take every default | `0` |
| `CBOOT_STD` | standard for the verification compile | `gnu89` |
| `CBOOT_SCAFFOLD_DIR` | also create a starter project there | *none* |
| `CBOOT_SKIP_VSCODE` | `1` = never touch VS Code | `0` |
| `CBOOT_MSYS2_ROOT` | MSYS2 location (Windows only) | `C:\msys64` |

Windows:

```powershell
$env:CBOOT_PROFILE='full'; $env:CBOOT_EDITOR='kate'; $env:CBOOT_SCAFFOLD_DIR="$HOME\c-lab"
irm https://raw.githubusercontent.com/xelasleepi/cready/main/install.ps1 | iex
```

Linux / WSL:

```bash
CBOOT_PROFILE=full CBOOT_EDITOR=both CBOOT_SCAFFOLD_DIR=~/c-lab bash install.sh
```

`CBOOT_STD` only accepts real GCC standard names (`c89`, `gnu89`, `c99`, …). Anything else
is rejected, because that value gets written into a generated Makefile.

### Starter project

With `CBOOT_SCAFFOLD_DIR` set you also get a ready-to-run folder:

```
main.c                          hello world, ANSI C with // comments
Makefile                        make / make run / make clean   (Linux only)
.vscode/tasks.json              Ctrl+Shift+B builds the open file
.vscode/launch.json             F5 builds and debugs with gdb
.vscode/c_cpp_properties.json   IntelliSense pinned to C89
```

---

## A note for WSL users

If you are on WSL, run **`install.sh` inside the distro**, because that is where your compiler
belongs. The script detects WSL and will *not* install the Linux GUI build of VS Code.
Instead, install VS Code **on Windows** and add the
[`ms-vscode-remote.remote-wsl`](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl)
extension, then run `code .` from your WSL shell. That is the supported setup; installing
a GUI editor inside WSL is not.

You do not need the Windows toolchain *and* the WSL one. Pick whichever matches where you
write your code.

---

## Troubleshooting

**`gcc` still not found after installing (Windows).**
Open a **new** terminal. Already-running shells and editors hold the PATH they started
with. If it still fails, check `C:\msys64\ucrt64\bin` is present in your user PATH.

**The compiler runs but produces no output and exits 1 (Windows).**
`gcc.exe` launches a backend, `cc1.exe`, which lives outside `bin\` and loads its DLLs
**from PATH**. If `C:\msys64\ucrt64\bin` is missing from PATH, `cc1.exe` dies with
`0xC0000135 STATUS_DLL_NOT_FOUND` before it can print anything, which looks like a
silent failure. Fix the PATH entry, or invoke gcc from a shell that has it.

**Download errors / timeouts mid-install (Windows).**
MSYS2 mirrors time out fairly often. The script already retries five times, and
completed downloads are cached, so just run it again and it picks up where it stopped.

**`make` is not found (Windows).**
MSYS2 names it **`mingw32-make`**. Either call that, or create a `make.cmd` shim.

**Permission denied (Linux).**
The script needs `sudo` for package installation. Run it as a normal user with sudo
rights, not as root via `curl | sudo bash`.

---

## What it does not do

- It does not modify the system-wide PATH, only your user PATH.
- It does not install a full IDE like CLion or Visual Studio.
- It does not touch an existing compiler without asking first.
- On Windows it does not add `C:\msys64\usr\bin` to PATH, because that directory shadows
  Windows and Git Bash tools like `find` and `ls` and causes confusing breakage.

## License

MIT. Use it, fork it, hand it to your classmates.
