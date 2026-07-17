# ADR 0001: Powtarzalny toolchain Windows Release

- **Status:** Accepted
- **Date:** 2026-07-17
- **Task:** NC-001

## Context

`engine-sim-app` jest aplikacją Windows zależną od MSVC/Windows SDK, DirectX i DirectSound. Projekt jest konfigurowany przez CMake, korzysta z przypiętych submodułów Git i pobiera GoogleTest przez `FetchContent`.

Czysty checkout nie był samowystarczalny:

- submoduł `piranha` wymaga Flex i Bison znalezionych przez lokalny `PATH`,
- przypięty `delta-studio` wymaga SDL2, SDL2_image i Boost.Filesystem,
- aktualny Boost usunął historyczne API `boost::filesystem::path::is_complete()` używane przez przypięty kod `piranha`,
- dotychczasowy workflow zakładał częściowo przygotowane środowisko i nie tworzył kompletnej paczki runtime.

NC-001 nie może zmieniać algorytmów ani zachowania symulacji, dlatego rozwiązanie musi dostarczyć kompatybilny toolchain bez patchowania kodu engine-sim i submodułów.

## Decision

Standardowym buildem jest:

- Windows x64,
- generator CMake `Visual Studio 17 2022`,
- konfiguracja `Release`,
- target `engine-sim-app`,
- CMake 3.21 lub nowszy,
- jedno polecenie: `pwsh -NoProfile -File .\tools\build-release.ps1`,
- katalog artefaktów: `artifacts/Release`.

### Przypięcie zależności

1. Submoduły Git są inicjalizowane rekurencyjnie i weryfikowane względem commitów zapisanych w checkoutcie.
2. WinFlexBison 2.5.25 jest pobierany z przypiętego URL i sprawdzany sumą SHA-256:

   ```text
   8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135
   ```

3. SDL2 i SDL2_image są instalowane przez vcpkg:

   ```text
   tag:    2026.05.25
   commit: d015e31e90838a4c9dfa3eed45979bc70d9357fc
   triplet: x64-windows
   ```

4. Boost.Filesystem 1.78.0 jest budowany bezpośrednio z oficjalnego archiwum Boost:

   ```text
   https://archives.boost.io/release/1.78.0/source/boost_1_78_0.zip
   SHA-256: f22143b5528e081123c3c5ed437e92f648fe69748e95fa6e2bd41484e2986cc3
   ```

   Wybrano 1.78.0, ponieważ zachowuje `path::is_complete()` wymagane przez przypięty `piranha`. Biblioteki `filesystem` i `system` są budowane statycznie dla x64/Release z dynamicznym runtime MSVC.

5. Wszystkie ścieżki Flex, Bison, SDL i Boost są przekazywane jawnie do CMake. Dla Boost ustawiono `Boost_NO_SYSTEM_PATHS=ON`.
6. Pobrane narzędzia są cache'owane w ignorowanym katalogu `.tools`, ale pierwszy clean build musi działać bez istniejącego cache.

### Zachowanie aplikacji

Pozostają włączone dotychczasowe opcje funkcjonalne:

- `PIRANHA_ENABLED=ON`,
- `DISCORD_ENABLED=ON`,
- `DTV=OFF`.

Nie zmieniono plików źródłowych aplikacji ani algorytmów symulacji.

### Paczka Release

Skrypt umieszcza w `artifacts/Release`:

- `bin/engine-sim-app.exe`,
- SDL2, SDL2_image oraz ich DLL-e zależne,
- zasoby aplikacji,
- fonty i shadery `delta-studio`,
- `delta.conf`,
- statyczne biblioteki wynikowe,
- launcher ustawiający właściwy katalog roboczy,
- `build-info.json` z czasami, środowiskiem, wersjami zależności i rewizjami submodułów.

## Consequences

### Positive

- Build działa od czystego checkoutu bez prywatnych ścieżek i ręcznej konfiguracji `PATH`.
- Każda zewnętrzna baza zależności jest przypięta przez commit, wersję i/lub SHA-256.
- Skrypt lokalny i CI używają dokładnie tej samej procedury.
- Paczka runtime ma stałą strukturę i może być uruchomiona przez dołączony launcher.
- Nie jest potrzebny patch do engine-sim ani `piranha`.
- Błędy procesów natywnych są propagowane jako niezerowy kod skryptu.

### Negative

- Pierwszy build wymaga sieci i trwa dłużej, ponieważ buduje SDL oraz Boost.
- Boost 1.78.0 pozostaje zależnością zgodnościową do czasu aktualizacji lub zastąpienia przypiętego `piranha`.
- Decyzja nie zapewnia builda Linux/macOS.
- Cache `.tools` może zajmować znaczną ilość miejsca; jego usunięcie wymusza pełny bootstrap.

## Rejected alternatives

- **Globalnie zainstalowane Flex/Bison, SDL lub Boost:** odrzucone z powodu niekontrolowanych wersji i zależności od lokalnych ścieżek.
- **Aktualny Boost 1.91:** odrzucony, ponieważ przypięty `piranha` nie kompiluje się po usunięciu `path::is_complete()`.
- **Historyczny vcpkg z Boost 1.78:** odrzucony, ponieważ jego porty odwołują się do usuniętych pakietów MSYS2 i clean build nie jest już powtarzalny.
- **Patch `piranha` z `is_complete()` na `is_absolute()`:** odrzucony w NC-001, ponieważ zmieniałby kod zależności; właściwym miejscem na taką migrację jest osobne zadanie z testami regresji.
- **Commitowanie binariów zależności do repozytorium:** odrzucone ze względu na rozmiar i trudniejszy audyt aktualizacji.
- **Zmiana systemu budowania:** odrzucona jako niepotrzebna; istniejący CMake jest wystarczający po kontrolowanym bootstrapie zależności.

## Validation

Decyzję zweryfikowano w GitHub Actions na świeżym `windows-2022` bez cache `.tools`:

```text
Workflow: NC-001 Release build
Run:      29577089173
Head:     6d835d6e24263899249ef6a90501f908922c909b
Result:   success
```

Build, walidacja struktury artefaktów i test niezerowego kodu błędu zakończyły się powodzeniem.
