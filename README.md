# RetroPal - Your Retro Gaming Companion

A modern, cross-platform Game Boy / Game Boy Color / Game Boy Advance emulator built with Flutter, powered by the mGBA core.

![RetroPal Banner](docs/banner.png)

## Features

- 🎮 **Multi-Platform Support**: Play GB, GBC, and GBA games
- 🚀 **Powered by mGBA**: Highly accurate emulation using the renowned mGBA core
- 📱 **Cross-Platform**: Runs on Windows, macOS, Linux, Android, and iOS
- 🎨 **Modern UI**: Beautiful, intuitive interface with dark theme
- 💾 **Save States**: Quick save and load with multiple slots
- 🎛️ **Virtual Gamepad**: Touch controls optimized for mobile
- ⚡ **Fast Forward**: Turbo mode for grinding through slow sections
- 📚 **Game Library**: Organize your ROM collection with favorites and recent games

## Screenshots

*(Screenshots coming soon)*

## Getting Started

### Prerequisites

- Flutter SDK 3.10.4 or higher
- For building native libraries:
  - CMake 3.16+
  - C compiler (MSVC, GCC, or Clang)
  - Pre-built mGBA library (see below)

### Building the Native Library

RetroPal requires a native wrapper library that interfaces with mGBA. Follow these steps:

1. **Build mGBA first:**
   ```bash
   git clone https://github.com/mgba-emu/mgba.git
   cd mgba
   mkdir build && cd build
   cmake .. -DBUILD_SHARED=ON -DBUILD_STATIC=OFF
   cmake --build . --config Release
   ```

2. **Build the RetroPal native library:**
   ```bash
   cd retropal/native
   mkdir build && cd build
   cmake .. -DMGBA_DIR=/path/to/mgba/build
   cmake --build . --config Release
   ```

3. **Copy the built libraries:**
   - Windows: Copy `yage_core.dll` and `mgba.dll` to the `windows/` folder
   - Linux: Copy `libyage_core.so` and `libmgba.so` to the appropriate location
   - macOS: Copy `libyage_core.dylib` and `libmgba.dylib` to the app bundle

### NES and SNES Cores (Android)

For NES and SNES support on Android, download the LibRetro cores and place them in `android/app/src/main/jniLibs/`:

**Option 1 — Run the fetch script (recommended):**
```powershell
# Windows
.\scripts\fetch_libretro_cores.ps1
```
```bash
# Linux/macOS
chmod +x scripts/fetch_libretro_cores.sh
./scripts/fetch_libretro_cores.sh
```

**Option 2 — Manual download:**
1. Go to https://buildbot.libretro.com/nightly/android/latest/
2. For each ABI (`armeabi-v7a`, `arm64-v8a`, `x86_64`):
   - Download `fceumm_libretro_android.so.zip` (NES)
   - Download `snes9x2010_libretro_android.so.zip` (SNES)
3. Extract each zip into `android/app/src/main/jniLibs/<abi>/`

Then rebuild: `flutter clean && flutter build apk`

### Running the App

```bash
# Get dependencies
flutter pub get

# Run on desktop
flutter run -d windows  # or macos, linux

# Run on mobile
flutter run -d android  # or ios
```

## Usage

### Adding Games

1. Click the **+** button or "Add Folder" to add ROM files
2. Supported formats: `.gba`, `.gb`, `.gbc`, `.sgb`
3. Your games will appear in the library

### Playing Games

1. Tap on a game to launch it
2. Use the virtual gamepad or keyboard controls
3. Press the menu button (top-left) to access in-game options

### Keyboard Controls (Desktop)

| Key | Action |
|-----|--------|
| Arrow Keys | D-Pad |
| Z | A Button |
| X | B Button |
| A | L Button |
| S | R Button |
| Enter | Start |
| Backspace | Select |
| F1-F4 | Quick Save Slots |
| Shift+F1-F4 | Quick Load Slots |

### Settings

- **Audio**: Enable/disable sound, adjust volume
- **Display**: FPS counter, aspect ratio, filtering
- **Controls**: Gamepad opacity, scale, haptic feedback
- **Emulation**: Turbo mode, skip BIOS
- **BIOS**: Configure BIOS files for enhanced compatibility

## Project Structure

```
retropal/
├── lib/
│   ├── core/           # mGBA FFI bindings
│   ├── models/         # Data models
│   ├── services/       # Business logic
│   ├── providers/      # State management
│   ├── screens/        # UI screens
│   ├── widgets/        # Reusable widgets
│   └── utils/          # Theme and utilities
├── native/             # C native library
│   ├── yage_libretro.c # mGBA wrapper implementation
│   ├── yage_libretro.h # C header file
│   └── CMakeLists.txt  # Native build config
├── assets/             # App assets
└── windows/            # Platform-specific code
```

## Technical Details

### Architecture

RetroPal uses a layered architecture:

1. **Native Layer** (`native/`): C wrapper around mGBA providing a simplified FFI interface
2. **Core Layer** (`lib/core/`): Dart FFI bindings to the native library
3. **Service Layer** (`lib/services/`): Emulator lifecycle, game library, settings management
4. **UI Layer** (`lib/screens/`, `lib/widgets/`): Flutter widgets and screens

### Frame Rendering

Frames are rendered using Flutter's `CustomPaint` with efficient pixel buffer transfers from the native layer. The game display supports both filtered (bilinear) and unfiltered (nearest neighbor) scaling.

### Audio

Audio is processed at 48kHz stereo and streamed through the platform's audio system. (Note: Audio output implementation varies by platform)

## Contributing

Contributions are welcome! Please read our contributing guidelines before submitting PRs.

### Development Setup

1. Fork and clone the repository
2. Set up Flutter development environment
3. Build the native library (see above)
4. Run `flutter pub get`
5. Start developing!

## Legal Notice

**IMPORTANT**: RetroPal does not include any copyrighted BIOS files or game ROMs. You must provide your own legally obtained ROM files and optional BIOS files.

- BIOS files improve compatibility but are optional (mGBA can run without them)
- Only use ROMs for games you legally own
- Downloading ROMs for games you don't own is piracy

## Credits

- **mGBA**: The excellent emulator core by endrift - https://mgba.io/
- **Flutter**: Google's UI toolkit - https://flutter.dev/
- **Icons**: Material Design Icons

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

The mGBA core is licensed under the Mozilla Public License 2.0.

---

Made with ❤️ for retro gaming enthusiasts
