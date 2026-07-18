# Budowanie engine-sim

## Obsługiwany baseline

Oficjalnym buildem projektu nEXTcAR jest obecnie:

```text
System:        Windows x64
Generator:     Visual Studio 17 2022
Konfiguracja:  Release
Target:        engine-sim-app
Katalog build: build/release
Artefakty:     artifacts/Release
```

Repozytorium używa CMake. Skrypt NC-001 nie zmienia kodu symulacji ani algorytmów `engine-sim`; przygotowuje toolchain, konfiguruje istniejący projekt i buduje aplikację z dotychczasowymi opcjami funkcjonalnymi.

## Build jednym poleceniem

Z katalogu głównego repozytorium:

```powershell
pwsh -NoProfile -File .\tools\build-release.ps1
```

Alternatywnie w Windows PowerShell 5.1:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build-release.ps1
```

Domyślnie skrypt usuwa `build/release` i `artifacts/Release`, inicjalizuje submoduły, przygotowuje przypięte zależności, konfiguruje CMake i buduje target `engine-sim-app` w konfiguracji `Release`.

## Wymagania systemowe

Wymagane są:

1. Windows 10/11 x64 albo Windows Server 2022 lub nowszy.
2. Visual Studio 2022 albo Visual Studio Build Tools 2022 z workloadem **Desktop development with C++** i Windows SDK.
3. CMake 3.21 lub nowszy.
4. Git z obsługą submodułów.
5. PowerShell 5.1 albo PowerShell 7.
6. Dostęp do internetu podczas pierwszego builda.

Nie jest wymagany Developer Command Prompt. Skrypt sprawdza obecność Git i CMake, minimalną wersję CMake oraz dostępność generatora Visual Studio przed rozpoczęciem konfiguracji.

Nie dodano `tools/build-release.sh`, ponieważ aktualna aplikacja i `delta-studio` korzystają z Windows API, DirectX i DirectSound; build Linux/macOS nie jest obsługiwanym baseline'em NC-001.

## System budowania

Główny `CMakeLists.txt`:

- wymaga C++17,
- dodaje zależności z `dependencies/`,
- buduje bibliotekę `engine-sim`,
- buduje aplikację `engine-sim-app`,
- używa wielokonfiguracyjnego generatora Visual Studio,
- zachowuje opcje:
  - `PIRANHA_ENABLED=ON`,
  - `DISCORD_ENABLED=ON`,
  - `DTV=OFF`.

Skrypt buduje wyłącznie target aplikacji, ale CMake podczas konfiguracji analizuje również deklaracje testów i zależności w submodułach.

## Pełna lista zależności

### Narzędzia hosta

| Zależność | Wersja / wymaganie | Rola |
| --- | --- | --- |
| Visual Studio / Build Tools | 2022, generator `Visual Studio 17 2022` | MSVC, linker i Windows SDK |
| CMake | co najmniej 3.21 | konfiguracja i sterowanie buildem |
| Git | wersja obsługująca submoduły | checkout zależności i kontrola przypiętych rewizji |
| PowerShell | 5.1 albo 7 | uruchomienie procesu builda |
| WinFlexBison | paczka 2.5.25 | generowanie parsera i leksera dla `piranha` |
| vcpkg | tag `2026.05.25`, commit `d015e31e90838a4c9dfa3eed45979bc70d9357fc` | przypięte SDL2 i zależności runtime |
| Boost | 1.78.0 | kompatybilny `Boost.Filesystem` wymagany przez przypięte `piranha` |

### Submoduły Git

Skrypt wykonuje:

```text
git submodule sync --recursive
git submodule update --init --recursive
git submodule status --recursive
```

Build kończy się błędem, jeżeli submoduł jest niezainicjalizowany, konfliktowy albo znajduje się na innej rewizji niż przypięta w checkoutcie.

Rewizje użyte w zweryfikowanym buildzie NC-001:

| Ścieżka | Commit | Rola |
| --- | --- | --- |
| `dependencies/submodules/csv-io` | `2112c55e1e831c8f7a1b91de23722b7926ad3d00` | odczyt danych CSV |
| `dependencies/submodules/delta-studio` | `b7d0a046733b924d12706baf1e5e59ba427aa7b1` | okno, renderowanie, audio, input i zasoby UI |
| `dependencies/submodules/direct-to-video` | `19f939c88d740d9e42755d6191daff5719be198f` | opcjonalny eksport wideo; wyłączony przez `DTV=OFF` |
| `dependencies/submodules/piranha` | `432f0b122bb1663b686c553c7e7269300afac3bc` | kompilator skryptów `.mr` |
| `dependencies/submodules/simple-2d-constraint-solver` | `e009f4ff1c9c4c5874e865e893cdb62e208fb2b3` | solver więzów symulacji |

### WinFlexBison

Skrypt pobiera:

```text
https://github.com/lexxmark/winflexbison/releases/download/v2.5.25/win_flex_bison-2.5.25.zip
SHA-256: 8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135
```

Archiwum jest weryfikowane przed rozpakowaniem. Narzędzia trafiają do `.tools/winflexbison/2.5.25`, a ich pełne ścieżki są przekazywane do CMake jako `FLEX_EXECUTABLE` i `BISON_EXECUTABLE`. Build nie zależy od prywatnych katalogów ani lokalnej konfiguracji `PATH` dla Flex/Bison.

Zweryfikowana paczka raportowała:

```text
win_flex.exe 2.6.4
GNU Bison 3.8.2
```

### SDL2 i zależności runtime

Skrypt klonuje przypięty vcpkg i instaluje dla tripletu `x64-windows`:

```text
sdl2:x64-windows
sdl2-image:x64-windows
```

W zweryfikowanym clean buildzie zainstalowano:

| Pakiet | Wersja |
| --- | --- |
| `sdl2` | 2.32.10 |
| `sdl2-image` | 2.8.12 |
| `libpng` | 1.6.58 |
| `zlib` | 1.3.2 |
| `vcpkg-cmake` | 2024-04-23 |
| `vcpkg-cmake-config` | 2024-05-23 |

CMake otrzymuje jawne ścieżki do nagłówków i bibliotek SDL. Pliki DLL wymagane w runtime są kopiowane do `artifacts/Release/bin`.

### Boost.Filesystem

Przypięty submoduł `piranha` używa historycznego API `boost::filesystem::path::is_complete()`, którego nie ma w aktualnym Boost 1.91. Zamiast modyfikować kod upstream, skrypt buduje kompatybilny Boost 1.78.0 z oficjalnego archiwum:

```text
https://archives.boost.io/release/1.78.0/source/boost_1_78_0.zip
SHA-256: f22143b5528e081123c3c5ed437e92f648fe69748e95fa6e2bd41484e2986cc3
```

Budowane są statyczne biblioteki `filesystem` i `system` dla x64, konfiguracji Release, z dynamicznym runtime MSVC. Nagłówki i biblioteki są przekazywane do `FindBoost` przez jawne ścieżki, z `Boost_NO_SYSTEM_PATHS=ON`.

### Zależności CMake i repozytorium

Projekt deklaruje GoogleTest przez CMake `FetchContent` z przypiętego commita:

```text
609281088cfefc76f9d0ce82e1ff6c30cc3591e5
```

GoogleTest jest pobierany podczas pierwszej konfiguracji, mimo że skrypt NC-001 buduje tylko target aplikacji i nie uruchamia testów jednostkowych.

`delta-studio` oraz repozytorium dostarczają lub wykorzystują również:

- DirectX / D3DCompiler,
- DirectSound,
- Vulkan loader/import library,
- OpenGL i `OpenGL32.lib`,
- `winmm.lib`, `dxguid.lib`, `dxgi.lib`,
- stb,
- statyczną bibliotekę Discord Rich Presence z `dependencies/discord`.

## Lokalizacja cache

Pobrane i zbudowane narzędzia są przechowywane w ignorowanym przez Git katalogu:

```text
.tools/
├── boost/1.78.0/
├── downloads/
├── vcpkg/2026.05.25/
└── winflexbison/2.5.25/
```

Domyślny clean build usuwa katalog CMake i paczkę Release, ale zachowuje `.tools`. Dzięki temu kolejne buildy nie muszą ponownie pobierać i kompilować wszystkich zależności. Usunięcie `.tools` wymusza pełną rekonstrukcję toolchainu.

## Artefakty Release

Po sukcesie powstaje przewidywalna paczka:

```text
artifacts/Release/
├── assets/
├── bin/
│   ├── engine-sim-app.exe
│   ├── SDL2.dll
│   ├── SDL2_image.dll
│   ├── libpng16.dll
│   ├── z.dll
│   └── delta.conf
├── engine-resources/
│   ├── fonts/
│   └── shaders/
├── lib/
│   ├── engine-sim.lib
│   ├── piranha.lib
│   └── ...
├── build-info.json
└── run-engine-sim.ps1
```

Uruchomienie aplikacji z wymaganym katalogiem roboczym:

```powershell
pwsh -NoProfile -File .\artifacts\Release\run-engine-sim.ps1
```

Launcher przechodzi do `artifacts/Release/bin`, ponieważ istniejąca aplikacja odczytuje `../assets/main.mr`, a `delta.conf` wskazuje `../engine-resources` i `../assets` względem katalogu procesu.

## Metadane i pomiar czasu

`artifacts/Release/build-info.json` zapisuje:

- commit źródłowy,
- czas przygotowania zależności,
- czas konfiguracji CMake,
- czas kompilacji,
- czas całkowity,
- system operacyjny i procesor,
- wersje PowerShell, CMake, Git, Visual Studio, Flex, Bison, vcpkg i Boost,
- listę pakietów vcpkg,
- dokładne rewizje submodułów.

Referencyjny clean build NC-001 wykonano 17 lipca 2026 na świeżym runnerze GitHub Actions `windows-2022`:

| Element | Wynik |
| --- | --- |
| System | Microsoft Windows Server 2022 Datacenter 10.0.20348 |
| Procesor | AMD64 Family 25 Model 1 Stepping 1, AuthenticAMD |
| PowerShell | 7.6.3 |
| CMake | 3.31.6 |
| Git | 2.55.0.windows.2 |
| Visual Studio | 17.14.35 (June 2026) |
| Przygotowanie zależności | 222,750 s |
| Konfiguracja CMake | 18,223 s |
| Kompilacja Release | 147,976 s |
| Całość skryptu | 392,211 s |

Pomiar obejmuje pierwszy przebieg bez cache `.tools`, w tym pobranie i zbudowanie zależności. Wynik pochodzi z workflow `NC-001 Release build`, run `29577089173`, dla head commita `6d835d6e24263899249ef6a90501f908922c909b`.

## Parametry skryptu

```powershell
# Zachowaj istniejący katalog CMake i paczkę artefaktów
pwsh .\tools\build-release.ps1 -NoClean

# Ogranicz równoległość kompilacji
pwsh .\tools\build-release.ps1 -Parallel 8

# Użyj innych katalogów wyjściowych
pwsh .\tools\build-release.ps1 `
    -BuildDirectory build/nc-001 `
    -ArtifactDirectory artifacts/NC-001

# Pomiń aktualizację submodułów przygotowanych wcześniej przez CI
pwsh .\tools\build-release.ps1 -SkipSubmoduleUpdate
```

Ścieżki względne są rozwiązywane względem katalogu głównego repozytorium, niezależnie od bieżącego katalogu powłoki.

## Build od czystego checkoutu

```powershell
git clone https://github.com/Dziuras98/engine-sim.git
cd engine-sim
git switch agent/nc-001-release-build
pwsh -NoProfile -File .\tools\build-release.ps1
```

`git clone --recurse-submodules` nie jest wymagane, ponieważ skrypt inicjalizuje submoduły rekurencyjnie.

## Kontrakt błędów

Skrypt zwraca kod `0` wyłącznie wtedy, gdy:

- wymagane narzędzia i generator są dostępne,
- submoduły odpowiadają przypiętym commitom,
- archiwa WinFlexBison i Boost przechodzą kontrolę SHA-256,
- checkout vcpkg odpowiada przypiętemu commitowi,
- zależności SDL i Boost zostały zbudowane,
- konfiguracja CMake zakończyła się sukcesem,
- target `engine-sim-app` został zlinkowany w `Release`,
- aplikacja, zasoby i biblioteki runtime zostały umieszczone w paczce.

Każdy wyjątek lub niezerowy kod procesu natywnego kończy skrypt kodem `1`. Workflow NC-001 weryfikuje ten kontrakt, uruchamiając skrypt także z celowo nieistniejącym generatorem.

## Ograniczenia i znane ostrzeżenia

- NC-001 nie zapewnia builda Linux/macOS.
- Pierwszy clean build wymaga sieci dla submodułów, GoogleTest, WinFlexBison, vcpkg, SDL i Boost.
- Kompilator raportuje istniejące ostrzeżenia MSVC `C4244` dotyczące konwersji liczbowych w kodzie engine-sim. Nie zostały zmienione, ponieważ korekty algorytmów są poza zakresem NC-001.
- Workflow potwierdza kompilację i strukturę paczki; nie uruchamia interaktywnego GUI na bezgłowym runnerze.
- Kod aplikacji i algorytmy symulacji pozostają niezmienione.
