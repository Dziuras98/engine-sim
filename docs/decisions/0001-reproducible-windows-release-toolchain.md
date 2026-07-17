# ADR 0001: Powtarzalny toolchain Windows Release

- **Status:** Accepted
- **Date:** 2026-07-17
- **Task:** NC-001

## Context

Obecny `engine-sim-app` jest aplikacją Windows zależną od MSVC/Windows SDK, DirectX i DirectSound. Projekt jest konfigurowany przez CMake, korzysta z przypiętych submodułów Git oraz pobiera GoogleTest przez `FetchContent`.

Submoduł `piranha` wykonuje `find_package(FLEX REQUIRED)` i `find_package(BISON REQUIRED)`. Dotychczas wymagało to ręcznej instalacji Flex/Bison oraz obecności nieudokumentowanych lokalnych ścieżek w `PATH`, co uniemożliwiało powtarzalny clean build.

## Decision

Standardowym buildem NC-001 jest:

- Windows x64,
- generator CMake `Visual Studio 17 2022`,
- konfiguracja `Release`,
- target `engine-sim-app`,
- CMake 3.21 lub nowszy,
- przypięte commity submodułów z bieżącego checkoutu,
- WinFlexBison 2.5.25 pobierany przez skrypt z przypiętego URL i sprawdzany przez SHA-256,
- jawne przekazanie `FLEX_EXECUTABLE` i `BISON_EXECUTABLE` do CMake,
- staging wyniku do `artifacts/Release`.

Domyślne opcje funkcjonalne pozostają zgodne z projektem:

- `PIRANHA_ENABLED=ON`,
- `DISCORD_ENABLED=ON`,
- `DTV=OFF`.

## Consequences

### Positive

- Build nie zależy od prywatnej lokalizacji Flex/Bison ani ręcznych zmian `PATH`.
- Wersja generatorów parsera jest stała i kontrolowana sumą SHA-256.
- Submoduły są synchronizowane i weryfikowane względem checkoutu.
- Artefakty oraz metadane środowiska i czasu kompilacji mają stałą lokalizację.
- Ten sam skrypt działa lokalnie i w GitHub Actions.

### Negative

- Pierwszy build wymaga dostępu do sieci dla submodułów, GoogleTest i WinFlexBison.
- Decyzja nie zapewnia builda Linux/macOS; obecna aplikacja pozostaje Windows-only.
- Visual Studio 2019 i inne generatory nie są częścią zweryfikowanego baseline, choć skrypt pozwala jawnie zmienić generator.

## Rejected alternatives

- **Wymaganie globalnie zainstalowanego Flex/Bison:** odrzucone z powodu zależności od lokalnego `PATH` i niekontrolowanej wersji.
- **Commitowanie binariów WinFlexBison do repozytorium:** odrzucone, ponieważ zwiększa repozytorium i utrudnia audyt aktualizacji; kontrolowany download daje równoważną powtarzalność.
- **Zmiana parsera lub usunięcie Piranha:** poza zakresem NC-001 i zmieniałaby funkcjonalność aplikacji.
- **Przejście na inny system budowania:** niepotrzebne; istniejący CMake wystarcza po usunięciu zależności od lokalnych ścieżek.
