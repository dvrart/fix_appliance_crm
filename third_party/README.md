# third_party

## flutter_pcm_sound

Локальная копия [`flutter_pcm_sound`](https://pub.dev/packages/flutter_pcm_sound) 3.3.3.
Оригинал собирается с `compileSdkVersion 33`, из-за этого AGP 9 падает:
androidx требует compileSdk 34+. В форке стоит `compileSdkVersion 36`.

## twilio_voice-0.5.0

Локальная копия пакета [`twilio_voice`](https://pub.dev/packages/twilio_voice) версии 0.5.0
с одним исправлением в `android/build.gradle`.

**Проблема:** оригинальный пакет использует
`getDefaultProguardFile('proguard-android.txt')`, который новые версии Android
Gradle Plugin (AGP) больше не поддерживают ("is no longer supported since it
includes `-dontoptimize`"). Из-за этого падает сборка (`assembleDebug`/`assembleRelease`)
с ошибкой ещё на этапе конфигурации Gradle-проекта.

**Исправление:** заменено на `getDefaultProguardFile('proguard-android-optimize.txt')`
в `third_party/twilio_voice-0.5.0/android/build.gradle`.

Подключается через `dependency_overrides` в `pubspec.yaml`:

```yaml
dependency_overrides:
  twilio_voice:
    path: third_party/twilio_voice-0.5.0
```

Как только в pub.dev выйдет версия `twilio_voice`, где это исправлено
официально, можно удалить `third_party/twilio_voice-0.5.0`, убрать
`dependency_overrides` и обновить версию в `dependencies`.
