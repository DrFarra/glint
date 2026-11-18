# Glint

Cliente de Twitch para iPhone hecho en SwiftUI (iOS 26). Sin cuenta: usa la API pública de Twitch.

- Reproductor con gestos: toque para mostrar controles, doble toque a los lados para saltar,
  arrastre horizontal para buscar, pellizco para llenar la pantalla.
- Rebobinar un directo hasta el principio de la emisión (pasa al VOD en curso).
- VODs con miniatura al arrastrar, progreso guardado y tramos silenciados marcados.
- Chat en vivo y repetición del chat en VODs, con emotes de Twitch, 7TV, BTTV y FFZ (animados).
- Historial de búsqueda con avatares, historial de VODs vistos, clips, avisos de directos.
- Bloqueo de los anuncios que Twitch mete en los directos.

## Descargar

La última IPA: **https://github.com/DrFarra/glint/releases/latest/download/Glint.ipa**

Instálala con [Sideloadly](https://sideloadly.io) (Windows o Mac): arrastra la IPA, pon tu Apple ID y pulsa **Start**.
Con un Apple ID gratuito la app caduca a los 7 días; vuelve a instalarla o deja que Sideloadly la refresque.

## Compilar

No hace falta Mac: cada push a `main` compila en GitHub Actions
([build.yml](.github/workflows/build.yml)), publica la IPA sin firmar como release `glint-N`
y sube capturas del simulador como artefacto `glint-screenshots`.

En un Mac:

```bash
brew install xcodegen
xcodegen generate
open Glint.xcodeproj
```
