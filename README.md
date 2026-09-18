# cready

**Français** · **[English version →](README.en.md)**

> **English speakers:** this tool is fully bilingual.
> Read the **[English README](README.en.md)**, or just run the installer — it asks you
> to pick a language before anything else. You can also force it with `CBOOT_LANG=en`.

Une seule commande pour passer d'une machine vierge à un environnement de développement
fonctionnel et **vérifié** : C, C++, C#, Rust, Go, Python ou Java, avec l'éditeur de
votre choix.

Je l'ai écrit pour les étudiants de l'**Université Sorbonne Paris Nord (Paris 13)** qui
commencent leurs TP de C ANSI, parce qu'installer un compilateur sous Windows est le
premier obstacle sur lequel tout le monde bloque. Le reste est venu ensuite. Ce projet
n'est ni affilié ni approuvé par l'université, et rien dans le code n'est spécifique à
Paris 13. **N'importe quel étudiant, dans n'importe quelle école, sur n'importe quelle
machine, peut l'utiliser.**

---

## Installation

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/xelasleepi/cready/main/install.ps1 | iex
```

### Linux, WSL ou macOS

```bash
curl -fsSL https://raw.githubusercontent.com/xelasleepi/cready/main/install.sh | bash
```

Le script pose trois questions, n'installe que ce que vous avez choisi, puis **prouve que
tout fonctionne** en compilant et en exécutant un vrai programme dans chaque langage
avant d'annoncer une réussite.

```
   +---------------------------------------+
   |   Langue  /  Language                 |
   +---------------------------------------+

     1) Francais   (par defaut / default)
     2) English

   Quels langages voulez-vous ?
   Choisissez-en un ou plusieurs, séparés par des virgules (ex. 1,3)

     1) C / C++       - gcc, g++, gdb, make, valgrind
     2) C#            - SDK .NET
     3) Rust          - rustup, cargo, rustc
     4) Go            - compilateur et outils Go
     5) Python        - python3 et pip
     6) Java          - JDK (javac, java)

   Quels éditeurs voulez-vous ?

     1) Visual Studio Code  - IDE complet, débogueur, IntelliSense
     2) Kate                - éditeur KDE léger
     3) Vim                 - éditeur en terminal, toujours disponible
     0) Aucun - j'ai déjà un éditeur
```

Aux questions par oui/non, le script accepte `o` comme `y`.

---

## Ce que vous obtenez

| Langage | Windows | Linux / WSL / macOS | Vérifié par |
|---|---|---|---|
| **C / C++** | MinGW-w64 via MSYS2 (UCRT64) | gcc, g++, gdb, make, valgrind | compilation + exécution C et C++ |
| **C#** | SDK .NET 8 | paquet de la distribution, sinon script Microsoft | enregistrement du SDK |
| **Rust** | rustup | rustup (installateur officiel) | compilation + exécution `rustc` |
| **Go** | winget | paquet de la distribution | `go run` |
| **Python** | winget | python3 + pip | exécution d'une instruction |
| **Java** | Microsoft OpenJDK 21 | JDK de la distribution | `javac` + `java` |

Chaque vérification est une vraie compilation suivie d'une exécution, pas une simple
lecture de numéro de version. C'est important : sur ma propre machine, le `python3` du
Microsoft Store se trouve bien dans le PATH et **échoue** dès qu'on lui demande
d'exécuter quoi que ce soit. Un simple test de version l'aurait déclaré fonctionnel.

Seul .NET fait exception : `dotnet new` suivi d'une première compilation prend des
dizaines de secondes, donc c'est l'enregistrement du SDK qui est vérifié.

### Les éditeurs

**VS Code** est le choix sûr : IntelliSense, un vrai débogueur, et un `launch.json`
généré pour que F5 compile et lance votre programme. Les extensions suivent les langages
réellement installés : une installation Python seule n'ajoute pas les outils C/C++.

**Kate** vaut le coup si VS Code vous paraît lourd. Il n'a aucun support du C intégré,
donc `clangd` est installé en même temps si vous avez choisi C/C++ ; activez ensuite
**Settings → Plugins → LSP Client**.

**Vim** est là pour le travail en terminal et les machines distantes. Si vous n'avez
aucune configuration vim, une configuration de départ est créée : coloration syntaxique,
indentation à 4 espaces, numéros de ligne, et F5 pour compiler et lancer un fichier C.
**Une configuration existante n'est jamais modifiée.**

Chaque étape est ignorée si elle est déjà faite. Relancer le script est sans risque, et
c'est la manière prévue de **reprendre une installation qui a échoué** : ce qui est
terminé est détecté, et les téléchargements partiels sont réutilisés.

---

## Le problème du C ANSI avec les commentaires `//`

Le C ANSI strict (C89/C90) n'autorise pas les commentaires de ligne `//`. Si votre cours
impose le C ANSI mais que vous voulez utiliser `//`, l'option qu'il vous faut est
**`-std=gnu89`** : la sémantique du C89, avec `//` accepté.

Mesuré sur GCC 16.2.0 :

| Option | Commentaires `//` | Résultat |
|---|---|---|
| `-std=c89 -pedantic` | `error: C++ style comments are not allowed in ISO C90` | **la compilation échoue** |
| `-std=gnu89` | accepté sans rien dire | **C89 + `//`**, la valeur par défaut ici |
| `-std=gnu89 -pedantic` | simple avertissement | compile, avec un warning |
| `-std=c99` | parfaitement légal | compile proprement |

```bash
gcc -std=gnu89 -Wall -Wextra main.c -o main
```

---

## Exécuter votre programme

C'est ce qui piège presque tout le monde en passant de Linux à Windows.

| Terminal | Commande |
|---|---|
| **cmd** | `main.exe` ou `.\main.exe`. `./main` ne fonctionne **pas** |
| **PowerShell** | `.\main.exe` (le `.\` est obligatoire) |
| **Git Bash / WSL / Linux** | `./main` |

`cmd` traite `/` comme le caractère d'option : `./main` échoue donc avec
`'.' n'est pas reconnu`. Sous Windows, GCC produit aussi un `.exe`, et sans `-o` le nom
par défaut est **`a.exe`**, pas `a.out`.

---

## Options

Définissez ces variables avant de lancer le script pour sauter les questions. Pratique
pour les machines de TP et les installations automatisées.

| Variable | Rôle | Défaut |
|---|---|---|
| `CBOOT_LANG` | `fr` ou `en` (saute la question de langue) | `fr` |
| `CBOOT_TOOLCHAINS` | parmi `cpp dotnet rust go python java`, séparés par des virgules | *demande* |
| `CBOOT_EDITOR` | parmi `vscode kate vim`, ou `none` | *demande* |
| `CBOOT_ASSUME_YES` | `1` = ne jamais demander, accepter tous les défauts | `0` |
| `CBOOT_STD` | standard pour la compilation de vérification C | `gnu89` |
| `CBOOT_SCAFFOLD_DIR` | crée aussi un projet C de départ à cet endroit | *aucun* |
| `CBOOT_MSYS2_ROOT` | emplacement de MSYS2 (Windows uniquement) | `C:\msys64` |

Windows :

```powershell
$env:CBOOT_TOOLCHAINS='cpp,rust'; $env:CBOOT_EDITOR='vscode,vim'
irm https://raw.githubusercontent.com/xelasleepi/cready/main/install.ps1 | iex
```

Linux / WSL :

```bash
CBOOT_TOOLCHAINS=cpp,python CBOOT_EDITOR=vim bash install.sh
```

Quand rien n'est défini et que le script ne peut pas poser de question (un `curl | bash`
redirigé, ou une CI), il installe **C/C++ uniquement** et aucun éditeur.

`CBOOT_STD` n'accepte que de vrais noms de standards GCC. Toute autre valeur est rejetée,
car elle est écrite dans un Makefile généré dont les recettes passent par un shell.

`CBOOT_PROFILE` des versions précédentes fonctionne toujours et correspond à
`CBOOT_TOOLCHAINS=cpp`.

### Projet de départ

Avec `CBOOT_SCAFFOLD_DIR`, vous obtenez aussi un dossier C prêt à l'emploi :

```
main.c                          hello world, C ANSI avec commentaires //
Makefile                        make / make run / make clean   (Linux uniquement)
.vscode/tasks.json              Ctrl+Maj+B compile le fichier ouvert
.vscode/launch.json             F5 compile et débogue avec gdb
.vscode/c_cpp_properties.json   IntelliSense réglé sur C89
```

Les fichiers existants ne sont jamais écrasés.

---

## Note pour les utilisateurs de WSL

Lancez **`install.sh` à l'intérieur de la distribution**, car c'est là que doit se
trouver votre compilateur. Le script détecte WSL et n'installera *pas* la version
graphique Linux de VS Code. Installez VS Code **sous Windows** et ajoutez l'extension
[`ms-vscode-remote.remote-wsl`](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl),
puis lancez `code .` depuis votre terminal WSL.

Kate sous WSL nécessite WSLg (bien sous Windows 11, pas sur les versions plus anciennes) ;
le script prévient et demande confirmation avant de l'installer là. Vim n'a pas ce
problème et reste le choix sûr sous WSL.

---

## Dépannage

**`gcc` reste introuvable après l'installation (Windows).**
Ouvrez un **nouveau** terminal. Les fenêtres et éditeurs déjà ouverts conservent le PATH
qu'ils avaient au démarrage. Idem pour Go, Java, .NET et Rust installés via winget.

**Le compilateur se lance, n'affiche rien et se termine avec le code 1 (Windows).**
`gcc.exe` lance un programme interne, `cc1.exe`, qui se trouve en dehors de `bin\` et
charge ses DLL **depuis le PATH**. Si `C:\msys64\ucrt64\bin` manque au PATH, `cc1.exe`
meurt avec `0xC0000135 STATUS_DLL_NOT_FOUND` avant d'avoir rien affiché, ce qui ressemble
à un échec silencieux.

**Erreurs ou délais de téléchargement pendant l'installation (Windows).**
Les miroirs MSYS2 tombent en timeout assez souvent. Le script réessaie cinq fois et les
téléchargements terminés sont mis en cache : relancez-le simplement.

**`make` est introuvable (Windows).**
MSYS2 le nomme **`mingw32-make`**.

**Permission refusée (Linux).**
Le script a besoin de `sudo` pour installer les paquets. Lancez-le en tant qu'utilisateur
normal disposant des droits sudo, et surtout pas en root via `curl | sudo bash`.

---

## Ce que le script ne fait pas

- Il ne modifie pas le PATH système, seulement votre PATH utilisateur.
- Il n'installe pas d'IDE complet comme CLion ou Visual Studio.
- Il ne touche pas à une chaîne d'outils ou à une configuration d'éditeur existante sans
  demander d'abord.
- Sous Windows, il n'ajoute pas `C:\msys64\usr\bin` au PATH, car ce dossier masque des
  outils Windows et Git Bash comme `find` et `ls` et provoque des pannes difficiles à
  comprendre.

## Licence

MIT. Utilisez-le, forkez-le, passez-le à vos camarades.
