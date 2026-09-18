# cready

**Français** · [English](README.md)

Une seule commande pour passer d'une machine vierge à un environnement C et C++
fonctionnel et **vérifié**.

Je l'ai écrit pour les étudiants de l'**Université Sorbonne Paris Nord (Paris 13)** qui
commencent leurs TP de C ANSI, parce qu'installer un compilateur sous Windows est le
premier obstacle sur lequel tout le monde bloque, et parce que les TP sont notés en C ANSI
alors que tout le monde veut quand même écrire des commentaires `//`.

Ce projet n'est ni affilié ni approuvé par l'université, et rien dans le code n'est
spécifique à Paris 13. **N'importe quel étudiant, dans n'importe quelle école, sur
n'importe quelle machine, peut l'utiliser.**

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

Le script vous demande ce dont vous avez besoin, n'installe que cela, puis **prouve que
tout fonctionne** en compilant et en exécutant un vrai programme avant d'annoncer une
réussite.

> Les questions du script s'affichent en anglais. Cette page explique chaque choix.

```
   What do you need this machine set up for?     (Pour quoi faire ?)

     1) C only        - C ANSI uniquement (gcc, gdb, make)
     2) C and C++     - ajoute le compilateur g++
     3) Full setup    - C, C++ et un éditeur

   Which editor do you want?                     (Quel éditeur ?)

     1) Visual Studio Code  - IDE complet, débogueur, IntelliSense
     2) Kate                - éditeur KDE léger, rapide, simple
     3) Both                - les deux
     4) Neither             - aucun, j'en ai déjà un
```

---

## Ce que vous obtenez

| | Windows | Linux / WSL / macOS |
|---|---|---|
| Compilateur | GCC MinGW-w64 via MSYS2 (UCRT64) | GCC de la distribution |
| Également installé | `g++`, `gdb`, `mingw32-make` | `g++`, `gdb`, `make`, `valgrind` |
| PATH | `C:\msys64\ucrt64\bin` ajouté au PATH **utilisateur** | déjà dans le PATH |
| Éditeur | VS Code et/ou Kate | VS Code et/ou Kate |
| Extras éditeur | `ms-vscode.cpptools`, `clangd` pour Kate | `ms-vscode.cpptools`, `clangd` pour Kate |
| Vérifié | compile **et exécute** un programme test | compile **et exécute** un programme test |

### Quel éditeur choisir ?

**VS Code** est le choix sûr : IntelliSense, un vrai débogueur, et grâce au `launch.json`
généré, la touche F5 compile et lance votre programme directement.

**Kate** vaut le coup si VS Code vous paraît lourd ou si votre machine est ancienne. Il
démarre instantanément et ne vous encombre pas. Il n'a aucun support du C intégré, donc
l'installateur met aussi en place `clangd` : après l'installation, activez
**Settings → Plugins → LSP Client** dans Kate et vous aurez la complétion et le
soulignement des erreurs.

Choisir « Both » installe les deux et vous laisse décider plus tard.

Chaque étape est ignorée si elle est déjà faite. Relancer le script est sans risque,
rapide, et c'est aussi la manière prévue de **reprendre une installation qui a échoué** :
ce qui est déjà terminé est détecté, et les téléchargements partiels sont réutilisés
depuis le cache.

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

Donc :

```bash
gcc -std=gnu89 -Wall -Wextra main.c -o main
```

Vous pouvez en choisir un autre à tout moment avec `CBOOT_STD` (voir plus bas).

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
| `CBOOT_PROFILE` | `c`, `cpp` ou `full` (saute la question) | *demande* |
| `CBOOT_EDITOR` | `vscode`, `kate`, `both` ou `none` | *demande* |
| `CBOOT_ASSUME_YES` | `1` = ne jamais demander, accepter tous les défauts | `0` |
| `CBOOT_STD` | standard utilisé pour la compilation de vérification | `gnu89` |
| `CBOOT_SCAFFOLD_DIR` | crée aussi un projet de départ à cet endroit | *aucun* |
| `CBOOT_SKIP_VSCODE` | `1` = ne jamais toucher à VS Code | `0` |
| `CBOOT_MSYS2_ROOT` | emplacement de MSYS2 (Windows uniquement) | `C:\msys64` |

Windows :

```powershell
$env:CBOOT_PROFILE='full'; $env:CBOOT_EDITOR='kate'; $env:CBOOT_SCAFFOLD_DIR="$HOME\c-lab"
irm https://raw.githubusercontent.com/xelasleepi/cready/main/install.ps1 | iex
```

Linux / WSL :

```bash
CBOOT_PROFILE=full CBOOT_EDITOR=both CBOOT_SCAFFOLD_DIR=~/c-lab bash install.sh
```

`CBOOT_STD` n'accepte que de vrais noms de standards GCC (`c89`, `gnu89`, `c99`, …). Toute
autre valeur est rejetée, car elle est écrite dans un Makefile généré.

### Projet de départ

Avec `CBOOT_SCAFFOLD_DIR`, vous obtenez aussi un dossier prêt à l'emploi :

```
main.c                          hello world, C ANSI avec commentaires //
Makefile                        make / make run / make clean   (Linux uniquement)
.vscode/tasks.json              Ctrl+Maj+B compile le fichier ouvert
.vscode/launch.json             F5 compile et débogue avec gdb
.vscode/c_cpp_properties.json   IntelliSense réglé sur C89
```

---

## Note pour les utilisateurs de WSL

Sous WSL, lancez **`install.sh` à l'intérieur de la distribution**, car c'est là que doit
se trouver votre compilateur. Le script détecte WSL et n'installera *pas* la version
graphique Linux de VS Code. À la place, installez VS Code **sous Windows** et ajoutez
l'extension
[`ms-vscode-remote.remote-wsl`](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl),
puis lancez `code .` depuis votre terminal WSL. C'est la configuration officiellement
prise en charge ; installer un éditeur graphique dans WSL ne l'est pas.

Vous n'avez pas besoin de la chaîne d'outils Windows *et* de celle de WSL. Choisissez
celle qui correspond à l'endroit où vous écrivez votre code.

---

## Dépannage

**`gcc` reste introuvable après l'installation (Windows).**
Ouvrez un **nouveau** terminal. Les fenêtres et éditeurs déjà ouverts conservent le PATH
qu'ils avaient au démarrage. Si cela ne suffit pas, vérifiez que
`C:\msys64\ucrt64\bin` figure bien dans votre PATH utilisateur.

**Le compilateur se lance, n'affiche rien et se termine avec le code 1 (Windows).**
`gcc.exe` lance un programme interne, `cc1.exe`, qui se trouve en dehors de `bin\` et
charge ses DLL **depuis le PATH**. Si `C:\msys64\ucrt64\bin` manque au PATH, `cc1.exe`
meurt avec `0xC0000135 STATUS_DLL_NOT_FOUND` avant d'avoir pu afficher quoi que ce soit,
ce qui ressemble à un échec silencieux. Corrigez l'entrée du PATH, ou lancez gcc depuis un
terminal qui la possède.

**Erreurs ou délais de téléchargement pendant l'installation (Windows).**
Les miroirs MSYS2 tombent en timeout assez souvent. Le script réessaie déjà cinq fois, et
les téléchargements terminés sont mis en cache : relancez-le simplement, il reprend là où
il s'était arrêté.

**`make` est introuvable (Windows).**
MSYS2 le nomme **`mingw32-make`**. Appelez-le sous ce nom, ou créez un raccourci
`make.cmd`.

**Permission refusée (Linux).**
Le script a besoin de `sudo` pour installer les paquets. Lancez-le en tant qu'utilisateur
normal disposant des droits sudo, et surtout pas en root via `curl | sudo bash`.

---

## Ce que le script ne fait pas

- Il ne modifie pas le PATH système, seulement votre PATH utilisateur.
- Il n'installe pas d'IDE complet comme CLion ou Visual Studio.
- Il ne touche pas à un compilateur déjà installé sans demander d'abord.
- Sous Windows, il n'ajoute pas `C:\msys64\usr\bin` au PATH, car ce dossier masque des
  outils Windows et Git Bash comme `find` et `ls` et provoque des pannes difficiles à
  comprendre.

## Licence

MIT. Utilisez-le, forkez-le, passez-le à vos camarades.
