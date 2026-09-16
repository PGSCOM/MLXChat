# Faro

Chat con modelos MLX corriendo en el propio dispositivo iOS: cualquier repo de
Hugging Face (no solo un catálogo cerrado), un servidor HTTP compatible con
OpenAI para usar la potencia del dispositivo desde otros equipos de tu red, y
cliente MCP para dar herramientas al modelo local.

## Estado

Fase 0: esqueleto de la app y la GitHub Action que compila el `.ipa`. El resto
de funcionalidad llega fase a fase (ver historial de commits).

## Compilar

Este repo no incluye un `.xcodeproj`; se genera con
[XcodeGen](https://github.com/yonaskolb/XcodeGen) a partir de `project.yml`:

```sh
brew install xcodegen
xcodegen generate
open Faro.xcodeproj
```

Requiere Xcode 26.4+ (Swift 6.3, exigido por `mlx-swift`).

## `.ipa` sin firmar

Cada push a `main`/`master` dispara `.github/workflows/ios.yml`, que compila
un `.ipa` **sin firmar** y lo sube como artefacto (y a la release, si hay tag
`vX.Y.Z`). No se instala en un iPhone de serie: hace falta re-firmarlo con
[AltStore](https://altstore.io), [Sideloadly](https://sideloadly.io) o
similar.

## Requisitos de dispositivo

Necesita Apple Silicon (A17 Pro+/M-series) y bastante RAM libre: la app pide
el entitlement de límite de memoria aumentado, pero un modelo de 3-4B en
4-bit igualmente ocupa varios GB.
