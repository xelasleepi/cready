# cready

**English** · [Français](README.md)

> This project is written for French students, so **French is the default**.
> Everything works identically in English: pick `2) English` at the first prompt,
> or run it with `CBOOT_LANG=en`.

One command that takes a blank machine to a working, **verified** development
environment — C, C++, C#, Rust, Go, Python or Java, with the editor of your choice.

I wrote it for **Université Sorbonne Paris Nord (Paris 13)** students starting their
ANSI C coursework, because setting up a compiler on Windows is the first thing that
stops people. It grew from there. It is not affiliated with or endorsed by the
university, and there is nothing Paris 13-specific in the code. **Any student, at any
school, on any machine, can run it.**

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

It asks three questions, installs only what you picked, and then **proves it works** by
compiling and running a real program in each language before claiming success.

```
   +---------------------------------------+
   |   Langue  /  Language                 |
   +---------------------------------------+

     1) Francais   (par defaut / default)
     2) English

   Which languages do you want?
   Pick one or several, separated by commas (e.g. 1,3)

     1) C / C++       - gcc, g++, gdb, make, valgrind    ~ 1.6 GB
     2) C#            - .NET SDK                         ~ 900 MB
     3) Rust          - rustup, cargo, rustc             ~ 1.5 GB
     4) Go            - go compiler and tools            ~ 550 MB
     5) Python        - python3 and pip                  ~ 150 MB
     6) Java          - JDK (javac, java)                ~ 350 MB

   Which editors do you want?

     1) Visual Studio Code  - full IDE, debugger        ~ 400 MB
     2) Kate                - lightweight KDE editor    ~ 300 MB
     3) Vim                 - terminal editor           ~  60 MB
     0) None - I already have an editor
```

---

## What you get

| Language | Windows | Linux / WSL / macOS | Approx. size | Verified by |
|---|---|---|---|---|
| **C / C++** | MinGW-w64 via MSYS2 (UCRT64) | distro gcc, g++, gdb, make, valgrind | 1.6 GB / 450 MB | compiling + running C and C++ |
| **C#** | .NET SDK 8 | distro package, else Microsoft's installer | ~900 MB | SDK registration |
| **Rust** | rustup | rustup (official installer) | ~1.5 GB | compiling + running `rustc` |
| **Go** | winget | distro package | ~550 MB | `go run` |
| **Python** | winget | distro python3 + pip | ~200 MB | executing a statement |
| **Java** | Microsoft OpenJDK 21 | distro JDK | ~400 MB | `javac` + `java` |

Editors: VS Code ~400 MB, Kate ~120–300 MB, Vim ~50 MB.

### Nothing is downloaded before you see the bill

Sizes appear next to every option while you are choosing, and once you have picked,
the script prints a plan and waits:

```
   About to install

     C / C++                already installed, nothing to download
     Go                     ~ 550 MB
     Visual Studio Code     ~ 400 MB
     ---------------------------------------------
     Estimated total        ~ 950 MB
     Free space on C:\        203.6 GB

   Sizes are approximate and include dependencies.

   Proceed with the installation? (y/n) [y]:
```

Anything already on your machine counts as **0 MB** and is labelled, so the total is
what will actually be downloaded, not a catalogue price.

Free space is checked against that total plus headroom, because installers unpack
before they clean up:

- **Less than the total** — refuses to start and tells you how much is needed.
- **Less than total + 25% + 500 MB** — warns, then lets you decide.
- **Space cannot be determined** — says so and continues rather than guessing.

Answering `n` exits without touching anything.

Every check is a real build and run, not a version string. That matters: on my own
machine the Microsoft Store's `python3` stub resolves fine on PATH and **fails** the
moment you ask it to execute anything — a version check would have called it working.

Only .NET is exempt: `dotnet new` plus a first build costs tens of seconds, so its SDK
registration is checked instead.

### Editors

**VS Code** is the safe default: IntelliSense, a real debugger, and a generated
`launch.json` so F5 builds and runs. Language extensions follow the languages you
actually installed — a Python-only setup does not drag in the C/C++ toolset.

**Kate** is worth picking if VS Code feels heavy. It has no built-in C support, so
`clangd` is installed alongside it when you chose C/C++; enable
**Settings → Plugins → LSP Client**.

**Vim** is there for terminal work and remote machines. If you have no vim config at
all, a starter one is written with syntax highlighting, 4-space indentation, line
numbers, and F5 bound to build-and-run for C files. **An existing config is never
touched.**

Every step is skip-if-present. Re-running is safe and is the supported way to **resume a
failed install**: finished work is detected and partial downloads are reused.

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

```bash
gcc -std=gnu89 -Wall -Wextra main.c -o main
```

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
| `CBOOT_TOOLCHAINS` | any of `cpp dotnet rust go python java`, comma-separated | *asks* |
| `CBOOT_EDITOR` | any of `vscode kate vim`, or `none` | *asks* |
| `CBOOT_ASSUME_YES` | `1` = never prompt, take every default | `0` |
| `CBOOT_STD` | standard for the C verification compile | `gnu89` |
| `CBOOT_SCAFFOLD_DIR` | also create a starter C project there | *none* |
| `CBOOT_MSYS2_ROOT` | MSYS2 location (Windows only) | `C:\msys64` |

Windows:

```powershell
$env:CBOOT_TOOLCHAINS='cpp,rust'; $env:CBOOT_EDITOR='vscode,vim'; $env:CBOOT_LANG='en'
irm https://raw.githubusercontent.com/xelasleepi/cready/main/install.ps1 | iex
```

Linux / WSL:

```bash
CBOOT_TOOLCHAINS=cpp,python CBOOT_EDITOR=vim CBOOT_LANG=en bash install.sh
```

When nothing is set and the script cannot prompt (a piped `curl | bash`, or CI), it
installs **C/C++ only** and no editor.

`CBOOT_STD` only accepts real GCC standard names. Anything else is rejected, because that
value is written into a generated Makefile whose recipes run through a shell.

`CBOOT_PROFILE` from older versions still works and maps onto `CBOOT_TOOLCHAINS=cpp`.

### Starter project

With `CBOOT_SCAFFOLD_DIR` set you also get a ready-to-run C folder:

```
main.c                          hello world, ANSI C with // comments
Makefile                        make / make run / make clean   (Linux only)
.vscode/tasks.json              Ctrl+Shift+B builds the open file
.vscode/launch.json             F5 builds and debugs with gdb
.vscode/c_cpp_properties.json   IntelliSense pinned to C89
```

Existing files are never overwritten.

---

## A note for WSL users

Run **`install.sh` inside the distro** — that is where your compiler belongs. The script
detects WSL and will *not* install the Linux GUI build of VS Code. Install VS Code **on
Windows** and add the
[`ms-vscode-remote.remote-wsl`](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl)
extension, then run `code .` from your WSL shell.

Kate under WSL needs WSLg (fine on Windows 11, not on older builds); the script warns and
asks before installing it there. Vim has no such problem and is the safe choice in WSL.

---

## Troubleshooting

**`gcc` still not found after installing (Windows).**
Open a **new** terminal. Already-running shells and editors hold the PATH they started
with. Same applies to Go, Java, .NET and Rust installed through winget.

**The compiler runs but produces no output and exits 1 (Windows).**
`gcc.exe` launches a backend, `cc1.exe`, which lives outside `bin\` and loads its DLLs
**from PATH**. If `C:\msys64\ucrt64\bin` is missing from PATH, `cc1.exe` dies with
`0xC0000135 STATUS_DLL_NOT_FOUND` before printing anything, which looks like a silent
failure.

**Download errors / timeouts mid-install (Windows).**
MSYS2 mirrors time out fairly often. The script retries five times and cached downloads
are reused, so just run it again.

**`make` is not found (Windows).**
MSYS2 names it **`mingw32-make`**.

**Permission denied (Linux).**
The script needs `sudo` for packages. Run it as a normal user with sudo rights, not as
root via `curl | sudo bash`.

---

## What it does not do

- It does not modify the system-wide PATH, only your user PATH.
- It does not install a full IDE like CLion or Visual Studio.
- It does not touch an existing toolchain or editor config without asking first.
- On Windows it does not add `C:\msys64\usr\bin` to PATH, because that directory shadows
  Windows and Git Bash tools like `find` and `ls` and causes confusing breakage.

## License

MIT. Use it, fork it, hand it to your classmates.
