# PanVK build for Winlator Mali

## GitHub Actions (рекомендуется)

1. Создай **пустой** репозиторий на GitHub, например `winlator-panvk`.
2. Запушь **только** эти файлы (или весь `winlator-mali`):

```
.github/workflows/build-panvk.yml
panvk/build-panvk.sh
panvk/README.md
```

3. GitHub → **Actions** → **Build PanVK** → **Run workflow**.
4. После успеха скачай artifact **panvk-tzst**.
5. Положи файл в Winlator:

```
app/app/src/main/assets/graphics_driver/panvk-25.3.0.tzst
```

6. Пересобери APK:

```bash
cd app && ./gradlew assembleDebug
```

## Локально

```bash
export ANDROID_NDK=$HOME/android-sdk/ndk/26.3.11579264
# опционально: sudo pacman -S libclc   # пропускает сборку libclc
./build-panvk.sh
```

По этапам (мало RAM):

```bash
STAGE=libclc  ./build-panvk.sh
STAGE=host    ./build-panvk.sh
STAGE=android ./build-panvk.sh
STAGE=pack    ./build-panvk.sh
```
