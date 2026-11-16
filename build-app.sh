#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Lecture OCR.app"
STAGING="build/Lecture OCR.app.build"
CONTENTS="$STAGING/Contents"
RES="$CONTENTS/Resources"
PYTHON_VERSION="3.11"
APP_IDENTIFIER="${LECTURE_OCR_BUNDLE_ID:-local.lectureocr.app}"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Сборка рассчитана на Apple Silicon (arm64)." >&2; exit 1
fi
if ! command -v swiftc >/dev/null; then
  echo "Установите Xcode Command Line Tools: xcode-select --install" >&2; exit 1
fi
if ! command -v uv >/dev/null; then
  echo "Нужен uv для загрузки встроенного Python. Установите его: brew install uv" >&2; exit 1
fi

rm -rf "$STAGING"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$RES/python"
mkdir -p "$CONTENTS/MacOS"
mkdir -p build
swiftc -O -parse-as-library -module-cache-path build/ModuleCache -target arm64-apple-macosx15.0 \
  -framework SwiftUI -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers \
  LectureOCR/App.swift LectureOCR/LibraryStore.swift -o "$CONTENTS/MacOS/LectureOCR"
swiftc -O -module-cache-path build/ModuleCache -target arm64-apple-macosx15.0 \
  -framework AppKit LectureOCR/make_icon.swift -o build/MakeLectureOCRIcon
ICONSET="$RES/AppIcon.iconset"
build/MakeLectureOCRIcon "$ICONSET"
rm -rf "$ICONSET"
REQ_HASH="$(shasum -a 256 LectureOCR/requirements.txt | awk '{print $1}')"
RUNTIME_STAMP="$APP/Contents/Resources/python/.lectureocr_requirements"
RUNTIME_SOURCE=""
for candidate in "$APP/Contents/Resources/python" "/Applications/Lecture OCR.app/Contents/Resources/python" "$HOME/Applications/Lecture OCR.app/Contents/Resources/python"; do
  if [[ -f "$candidate/.lectureocr_requirements" && "$(cat "$candidate/.lectureocr_requirements")" == "$REQ_HASH" ]]; then
    RUNTIME_SOURCE="$candidate"
    break
  fi
done
if [[ -n "$RUNTIME_SOURCE" ]]; then
  cp -R "$RUNTIME_SOURCE/." "$RES/python/"
else
  UV_CACHE_DIR="$PWD/build/uv-cache" UV_PYTHON_INSTALL_DIR="$RES/python" uv python install "$PYTHON_VERSION"
  PYTHON="$(find "$RES/python" -type f -path '*/bin/python3.11' -print -quit)"
  if [[ -z "$PYTHON" ]]; then echo "Не найден загруженный Python 3.11." >&2; exit 1; fi
  mkdir -p "$RES/python/site-packages"
  UV_CACHE_DIR="$PWD/build/uv-cache" uv pip install --python "$PYTHON" --target "$RES/python/site-packages" -r LectureOCR/requirements.txt
  PYDIR="$(basename "$(dirname "$(dirname "$PYTHON")")")"
  mkdir -p "$RES/python/bin"
  ln -s "../$PYDIR/bin/python3.11" "$RES/python/bin/python3"
  echo "$REQ_HASH" > "$RES/python/.lectureocr_requirements"
fi
cp LectureOCR/worker.py LectureOCR/export_docx.py "$RES/"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Lecture OCR</string>
  <key>CFBundleDisplayName</key><string>Lecture OCR</string>
  <key>CFBundleIdentifier</key><string>${APP_IDENTIFIER}</string>
  <key>CFBundleExecutable</key><string>LectureOCR</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local OCR application</string>
</dict></plist>
PLIST
printf 'APPL????' > "$CONTENTS/PkgInfo"
find "$RES/python" -type d -name __pycache__ -prune -exec rm -rf {} +
chmod -R a+rX "$STAGING"
rm -rf "$APP"
mv "$STAGING" "$APP"
find "$APP/Contents/Resources/python" -type l -exec sh -c 'for path do [ -e "$path" ] || rm -f "$path"; done' sh {} +
codesign --force --sign - "$APP"
echo "Собрано: $APP"
echo "Каталог моделей по умолчанию: ~/Library/Application Support/Lecture OCR/PaddleX/official_models (его можно изменить в настройках приложения)."
