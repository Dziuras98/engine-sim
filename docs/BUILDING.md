# Budowanie engine-sim

## Zakres

Repozytorium jest obecnie przeznaczone do budowania na Windows. Oficjalną ścieżką dla projektu nEXTcAR jest build x64 w konfiguracji `Release`, wykonywany skryptem `tools/build-release.ps1`.

Skrypt nie modyfikuje kodu symulacji. Konfiguruje istniejący projekt CMake, inicjalizuje zależności i umieszcza wynik w przewidywalnym katalogu.

## Jedno polecenie

Z katalogu głównego repozytorium:

```powershell
pwsh -NoProfile -File .\tools\build-release.ps1
```

W Windows PowerShell 5.1:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build-release.ps1
```

Domyślnie skrypt usuwa poprzednie katalogi `build/release` i `artifacts/Release`, konfiguruje projekt od nowa i buduje target `engine-sim-app`.

## Wymagane narzędzia

1. Windows 10/11 x64 albo Windows Server z kompatybilnym Windows SDK.
2. Visual Studio 2022 lub Visual Studio Build Tools 2022 z workloadem **Desktop development with C++**.
3. CMake 3.21 lub nowszy.
4. Git z obsługą submodułów.
5. PowerShell 5.1 albo PowerShell 7.
6. Dostęp do internetu podczas pierwszej konfiguracji:
   - pobranie submodułów Git,
   - pobranie GoogleTest przez CMake `FetchContent`,
   - pobranie przypiętego WinFlexBison.

Skrypt sprawdza obecność Git i CMake, minimalną wersję CMake oraz dostępność generatora Visual Studio. Nie wymaga uruchomienia z Developer Command Prompt.

## Pełna lista zależności

### Narzędzia systemowe

| Zależność | Wersja / źródło | Zastosowanie |
|---|---|---|
| Visual Studio / Build Tools | 2022, generator `Visual Studio 17 2022` | kompilator MSVC, linker i Windows SDK |
| CMake | co najmniej 3.21 | konfiguracja i sterowanie buildem |
| Git | wersja obsługująca submoduły | checkout przypiętych zależności |
| PowerShell | 5.1 lub 7 | uruchomienie procesu builda |
| WinFlexBison | 2.5.25 | generowanie parsera i leksera w submodule `piranha` |

WinFlexBison jest pobierany automatycznie z przypiętego URL i weryfikowany przez SHA-256:

```text
8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135
```

Pliki trafiają do ignorowanego przez Git katalogu `.tools/winflexbison/2.5.25`. Skrypt przekazuje do CMake jawne wartości `FLEX_EXECUTABLE` i `BISON_EXECUTABLE`, dzięki czemu build nie zależy od prywatnych katalogów ani lokalnego `PATH` dla Flex/Bison.

### Submoduły przypięte przez Git

| Ścieżka | Repozytorium | Rola |
|---|---|---|
| `dependencies/submodules/delta-studio` | `ange-yaghi/delta-studio` | okno, rendering DirectX 11, audio DirectSound, input i zasoby UI |
| `dependencies/submodules/simple-2d-constraint-solver` | `ange-yaghi/simple-2d-constraint-solver` | solver więzów używany przez symulację |
| `dependencies/submodules/csv-io` | `ange-yaghi/csv-io` | obsługa danych CSV |
| `dependencies/submodules/piranha` | `ange-yaghi/piranha` | kompilator skryptów `.mr` |
| `dependencies/submodules/direct-to-video` | `ange-yaghi/direct-to-video` | opcjonalny eksport wideo; domyślnie wyłączony przez `DTV=OFF` |

Skrypt wykonuje:

```text
git submodule sync --recursive
git submodule update --init --recursive
```

Następnie sprawdza, czy każdy submoduł jest dokładnie na commicie przypiętym w checkoutcie. Stan niezgodny, niezainicjalizowany lub konfliktowy kończy build błędem.

### Zależności pobierane przez CMake

Projekt główny i część submodułów deklarują GoogleTest przez `FetchContent` z przypiętego commita:

```text
609281088cfefc76f9d0ce82e1ff6c30cc3591e5
```

GoogleTest jest potrzebny podczas konfiguracji CMake, mimo że standardowy skrypt buduje wyłącznie target aplikacji i nie uruchamia testów.

### Zależności dostarczone w repozytoriach

`delta-studio` zawiera wymagane nagłówki lub biblioteki importowe dla:

- D3DX i D3DCompiler,
- DirectSound,
- Vulkan loader/import library,
- OpenGL headers,
- stb.

Build korzysta także z bibliotek Windows SDK:

- `d3d9.lib`, `d3d10.lib`, `d3d11.lib`,
- `dxguid.lib`, `dxgi.lib`,
- `winmm.lib`,
- `OpenGL32.lib`.

Obsługa Discord Rich Presence jest domyślnie zachowana (`DISCORD_ENABLED=ON`) i korzysta z kodu oraz statycznej biblioteki znajdujących się w `dependencies/discord`.

## Konfiguracja wykonywana przez skrypt

Domyślne parametry CMake:

```text
Generator: Visual Studio 17 2022
Architecture: x64
Configuration: Release
Target: engine-sim-app
DTV: OFF
PIRANHA_ENABLED: ON
DISCORD_ENABLED: ON
```

Dla kompatybilności ze współczesnym CMake skrypt ustawia `CMAKE_POLICY_VERSION_MINIMUM=3.5`. Nie zmienia to algorytmów ani opcji funkcjonalnych aplikacji.

## Artefakty

Po sukcesie powstaje:

```text
artifacts/Release/
├── assets/
├── bin/
│   ├── delta.conf
│   └── engine-sim-app.exe
├── engine-resources/
│   ├── fonts/
│   └── shaders/
├── lib/
├── build-info.json
└── run-engine-sim.ps1
```

`build-info.json` zapisuje:

- commit źródłowy,
- czas konfiguracji,
- czas kompilacji,
- całkowity czas wykonania,
- system operacyjny i procesor,
- wersje PowerShell, CMake, Git, Visual Studio, Flex i Bison,
- generator i architekturę,
- dokładny stan submodułów.

Uruchomienie z poprawnym katalogiem roboczym:

```powershell
pwsh -NoProfile -File .\artifacts\Release\run-engine-sim.ps1
```

Launcher przechodzi do katalogu `bin`, ponieważ istniejąca aplikacja odczytuje `../assets/main.mr` względem bieżącego katalogu roboczego.

## Parametry skryptu

Przykłady:

```powershell
# Build bez czyszczenia istniejących katalogów
pwsh .\tools\build-release.ps1 -NoClean

# Ograniczenie liczby równoległych zadań
pwsh .\tools\build-release.ps1 -Parallel 8

# Własne katalogi wyjściowe
pwsh .\tools\build-release.ps1 `
    -BuildDirectory build/nc-001 `
    -ArtifactDirectory artifacts/NC-001

# Checkout, w którym submoduły zostały już przygotowane przez CI
pwsh .\tools\build-release.ps1 -SkipSubmoduleUpdate
```

Każda ścieżka względna jest interpretowana względem katalogu głównego repozytorium, a nie bieżącego katalogu powłoki.

## Build od czystego checkoutu

```powershell
git clone https://github.com/Dziuras98/engine-sim.git
cd engine-sim
git switch agent/nc-001-release-build
pwsh -NoProfile -File .\tools\build-release.ps1
```

Nie jest wymagane użycie `--recurse-submodules`, ponieważ skrypt inicjalizuje submoduły samodzielnie.

## Kontrakt błędów

Skrypt kończy się kodem `0` tylko wtedy, gdy:

- wymagane narzędzia są dostępne,
- generator Visual Studio jest dostępny,
- WinFlexBison przechodzi kontrolę SHA-256,
- submoduły są kompletne i przypięte,
- konfiguracja CMake kończy się sukcesem,
- target `engine-sim-app` kompiluje się w `Release`,
- `engine-sim-app.exe` istnieje w katalogu artefaktów,
- wymagane zasoby runtime zostały skopiowane.

Każde niepowodzenie jest raportowane na stderr/stdout i kończy proces kodem `1`.

## Ograniczenia

- Build Linux/macOS nie jest częścią NC-001. Kod aplikacji i `delta-studio` używają Windows API, DirectX i DirectSound.
- Pierwszy build wymaga sieci z powodu `FetchContent` oraz submodułów.
- NC-001 nie zmienia algorytmów engine-sim ani zachowania symulacji.
