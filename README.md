# AI Recorder

MVP local para iOS 26 que graba audio y lo transcribe progresivamente con
Nemotron 3.5 ASR Streaming Multilingual. También incluye un adaptador para
Apple `SpeechAnalyzer` / `SpeechTranscriber`, importación de M4A, CAF y WAV,
SwiftData y reproducción sincronizada por frases.

## Requisitos

- Xcode 26 o posterior y un iPhone con iOS 26.
- Acceso aceptado al repositorio restringido
  `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`.
- Un token de Hugging Face con permiso de lectura.

FluidAudio está fijado al commit
`5390df9752c8fc583596018360c5fd70d6fa6c75` en el proyecto Xcode.

## Configuración local

1. Abre `AIRecorder.xcodeproj`.
2. En **Product > Scheme > Edit Scheme > Run > Arguments**, agrega una
   variable de entorno `HF_TOKEN` con tu token. No la agregues a ningún archivo
   del proyecto ni al control de versiones.
3. Selecciona tu equipo de firma y un iPhone real.
4. Ejecuta la app. Al iniciar la primera grabación con Nemotron se descarga
   únicamente el bundle multilingüe de 1120 ms. FluidAudio lo conserva en
   Application Support y reporta el progreso a la interfaz.

## Privacidad y archivos

No hay servicios cloud configurados. Grabaciones y transcripciones viven bajo
`Application Support/Recordings/<UUID>/`; SwiftData sólo conserva rutas
relativas. Salir al segundo plano pausa la grabación y requiere reanudarla de
forma manual.

## Verificación local

El target es iOS 26. En una máquina que aún tenga Xcode 16.3 se puede verificar
el código no dependiente del SDK 26 usando temporalmente un deployment target
18 por línea de comandos. En ese caso `AppleSpeechEngine` compila como un stub;
el adaptador real se activa con el compilador Swift incluido en Xcode 26.

La aceptación final requiere un iPhone real porque el micrófono, Apple Speech,
la Neural Engine y el modelo protegido no pueden validarse completamente en un
simulador.

## Licencia del modelo

Nemotron 3.5 ASR Streaming 0.6B es de NVIDIA y se distribuye bajo
[OpenMDW 1.1](https://openmdw.ai/license/1-1/). La misma atribución aparece en
la pantalla **Ajustes > Acerca de**.
