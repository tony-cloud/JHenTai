---
applyTo: "**"
---
# Deprecated API Usage Guide

## Notice
To avoid errors, do not use deprecated APIs. If an API is marked as deprecated, search online and use the suggested replacement.

# Collaboration Notice
To facilitate collaboration, the prompt file must be written in English.

# Color Class Deprecation Notice
For the Color class, the following properties are deprecated:
- `red`, `green`, `blue`, `alpha` (type: int, range: 0-255)
Use instead:
- `r`, `g`, `b`, `a` (type: double, range: 0.0-1.0)

**IMPORTANT**: When migrating from old to new properties, you need to convert the range:
- From old int properties (0-255) to new double properties (0.0-1.0): divide by 255.0
- From new double properties (0.0-1.0) to old int properties (0-255): multiply by 255.0 and convert to int

Migration examples:
```dart

// Converting from new to old format when needed:
int redValue = (color.r * 255.0).round();
int greenValue = (color.g * 255.0).round();
int blueValue = (color.b * 255.0).round();
int alphaValue = (color.a * 255.0).round();

// Using in Color.fromRGBO (which expects int values 0-255):
Color newColor = Color.fromRGBO(
  (color.r * 255.0).round(),
  (color.g * 255.0).round(), 
  (color.b * 255.0).round(),
  1.0 // opacity as double 0.0-1.0
);
```

# Opacity Deprecation Notice
The following APIs are also deprecated:
- `opacity` (type: double, range: 0-1)
- `withOpacity(double opacity)`

Use instead:
- `a` (type: double, range: 0-1) for alpha channel
- `withValues(alpha: ...)` to create a new color with the specified alpha

Migration examples:
```dart
// Deprecated
double alpha = color.opacity;
final faded = color.withOpacity(0.5);

// Recommended
double alpha = color.a;
final faded = color.withValues(alpha: 0.5);
```

## 2025-10-27
- Replaced `Color.withOpacity(...)` calls with `Color.withValues(alpha: ...)` to follow the updated `Color` channel API.
- Use `Color.toARGB32()` instead of the deprecated `Color.value` when serializing theme and tag colors.
- Migrated `Share.share`/`Share.shareXFiles` usage to `SharePlus.instance.share` with `ShareParams` (Share Plus 12.x API).
- Updated `ScreenBrightness` calls to `setApplicationScreenBrightness`/`resetApplicationScreenBrightness`.
- Removed the deprecated `allowCompression` flag from `FilePicker.platform.pickFiles`; rely on `compressionQuality` (set to 100 for lossless imports).
- Replaced `FontAwesomeIcons.redoAlt` with the new `FontAwesomeIcons.rotateRight`.
- Wrapped `RadioListTile` sets in `RadioGroup` to eliminate deprecated `groupValue`/`onChanged` parameters.