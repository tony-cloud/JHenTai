import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'file_operations.dart';

/// Provides direct access to the physical file system, with no virtual mapping.
/// All operations are performed relative to a single root directory.
///
/// Main difference from VirtualFileOperations:
/// - PhysicalFileOperations allows writing, creating, and deleting files/directories at the root directory.
/// - VirtualFileOperations does NOT allow writing to the virtual root (`/`).
///
/// Limitations:
/// - Operations outside the root directory are not allowed.
/// - No virtual mapping or aliasing; paths are resolved directly.
class PhysicalFileOperations extends FileOperations {
  static const int _maxFdRetries = 3;
  static const Duration _fdRetryDelay = Duration(milliseconds: 50);

  PhysicalFileOperations(String root, {String? startingDirectory}) : super(p.normalize(root)) {
    if (!Directory(root).existsSync()) {
      throw ArgumentError("Root directory does not exist: $root");
    }
    currentDirectory = p.normalize(startingDirectory ?? rootDirectory);
    if (!p.isWithin(rootDirectory, currentDirectory) &&
        !p.equals(rootDirectory, currentDirectory)) {
      throw ArgumentError(
          "Starting directory must be within the root directory: $startingDirectory");
    }
  }

  @override
  String resolvePath(String path) {
    // '.' or '' means current directory, '/' means root
    if (path.isEmpty || path == '.') {
      return currentDirectory;
    }
    if (path == '/' || p.normalize(path) == p.separator) {
      return rootDirectory;
    }
    final cleanPath = p.normalize(path);

    // Handle absolute paths that are already within the root.
    if (p.isAbsolute(cleanPath)) {
      final normalizedAbsolute = p.normalize(cleanPath);
      // Case 1: absolute and already inside root -> allow as-is.
      if (p.isWithin(rootDirectory, normalizedAbsolute) ||
          p.equals(rootDirectory, normalizedAbsolute)) {
        return normalizedAbsolute;
      }

      // Case 2: FTP-style absolute (starting with '/') that should be treated as root-relative.
      final String stripped = normalizedAbsolute.startsWith(p.separator)
          ? normalizedAbsolute.substring(1)
          : normalizedAbsolute;
      final String remapped = p.normalize(p.join(rootDirectory, stripped));
      if (!p.isWithin(rootDirectory, remapped) && !p.equals(rootDirectory, remapped)) {
        throw FileSystemException(
            "Path resolution failed: Path is outside the root directory", remapped);
      }
      return remapped;
    }

    // Handle relative paths from the current directory.
    final absPath = p.normalize(p.join(currentDirectory, cleanPath));
    if (!p.isWithin(rootDirectory, absPath) && !p.equals(rootDirectory, absPath)) {
      throw FileSystemException(
          "Path resolution failed: Path is outside the root directory", absPath);
    }
    return absPath;
  }

  @override
  void changeDirectory(String path) {
    final targetPath = resolvePath(path);
    final dir = Directory(targetPath);
    if (!dir.existsSync() ||
        FileSystemEntity.typeSync(targetPath) != FileSystemEntityType.directory) {
      throw FileSystemException(
          "Directory not found or not a directory: $path (resolved to $targetPath)", path);
    }
    currentDirectory = targetPath;
  }

  @override
  void changeToParentDirectory() {
    if (currentDirectory == rootDirectory) {
      throw FileSystemException("Cannot navigate above root", currentDirectory);
    }
    final parent = p.dirname(currentDirectory);
    changeDirectory(parent);
  }

  @override
  Future<List<FileSystemEntity>> listDirectory(String path) async {
    return _withFdRetry(() async {
      final dirPath = resolvePath(path);
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        throw FileSystemException("Directory not found: $path (resolved to $dirPath)", path);
      }
      // On iOS, Directory.list() uses a stream that may delay releasing the underlying
      // directory handle under heavy churn. listSync() keeps the handle lifetime strictly
      // within this call.
      return dir.listSync(followLinks: false);
    });
  }

  @override
  Future<File> getFile(String path) async {
    final filePath = resolvePath(path);
    if (filePath == rootDirectory) {
      throw FileSystemException("Cannot get root as a file", path);
    }
    return File(filePath);
  }

  @override
  Future<void> writeFile(String path, List<int> data) async {
    await _withFdRetry(() async {
      final filePath = resolvePath(path);
      final file = File(filePath);
      // If the path exists and is a directory, throw
      if (await FileSystemEntity.type(filePath) == FileSystemEntityType.directory) {
        throw FileSystemException("Cannot write to a directory as a file", filePath);
      }
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data);
    });
  }

  @override
  Future<List<int>> readFile(String path) async {
    return _withFdRetry(() async {
      final file = await getFile(path);
      if (!await file.exists()) {
        throw FileSystemException("File not found: $path (resolved to ${file.path})");
      }
      return await file.readAsBytes();
    });
  }

  @override
  Future<void> createDirectory(String path) async {
    await _withFdRetry(() async {
      final dirPath = resolvePath(path);
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    });
  }

  @override
  Future<void> deleteFile(String path) async {
    await _withFdRetry(() async {
      final file = await getFile(path);
      if (await file.exists()) {
        await file.delete();
      } else {
        throw FileSystemException("File not found for deletion: $path (resolved to ${file.path})");
      }
    });
  }

  @override
  Future<void> deleteDirectory(String path) async {
    await _withFdRetry(() async {
      final dirPath = resolvePath(path);
      if (dirPath == rootDirectory) {
        throw FileSystemException("Cannot delete root directory", path);
      }
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      } else {
        throw FileSystemException("Directory not found for deletion: $path (resolved to $dirPath)");
      }
    });
  }

  @override
  Future<int> fileSize(String path) async {
    return _withFdRetry(() async {
      final file = await getFile(path);
      if (!await file.exists()) {
        throw FileSystemException(
            "File not found for size check: $path (resolved to ${file.path})");
      }
      return await file.length();
    });
  }

  @override
  bool exists(String path) {
    try {
      final fullPath = resolvePath(path);
      if (fullPath == rootDirectory) {
        return true;
      }
      return File(fullPath).existsSync() || Directory(fullPath).existsSync();
    } catch (e) {
      return false;
    }
  }

  @override
  String getCurrentDirectory() {
    if (p.equals(currentDirectory, rootDirectory)) {
      return '/';
    }
    return p.relative(currentDirectory, from: rootDirectory);
  }

  @override
  Future<void> renameFileOrDirectory(String oldPath, String newPath) async {
    await _withFdRetry(() async {
      final oldFullPath = resolvePath(oldPath);
      final newFullPath = resolvePath(newPath);

      // Prevent renaming the root directory
      if (oldFullPath == rootDirectory) {
        throw FileSystemException("Cannot rename root directory", oldPath);
      }

      // Check if source exists
      final sourceEntity = FileSystemEntity.typeSync(oldFullPath);
      if (sourceEntity == FileSystemEntityType.notFound) {
        throw FileSystemException(
            "Source not found for rename: $oldPath (resolved to $oldFullPath)");
      }

      // Check if destination already exists
      if (FileSystemEntity.typeSync(newFullPath) != FileSystemEntityType.notFound) {
        throw FileSystemException(
            "Destination already exists: $newPath (resolved to $newFullPath)");
      }

      try {
        if (sourceEntity == FileSystemEntityType.file) {
          final file = File(oldFullPath);
          await file.rename(newFullPath);
        } else if (sourceEntity == FileSystemEntityType.directory) {
          final directory = Directory(oldFullPath);
          await directory.rename(newFullPath);
        } else {
          throw FileSystemException("Unsupported file system entity type for rename", oldPath);
        }
      } catch (e) {
        throw FileSystemException("Failed to rename $oldPath to $newPath: $e");
      }
    });
  }

  @override
  PhysicalFileOperations copy() {
    return PhysicalFileOperations(rootDirectory, startingDirectory: currentDirectory);
  }

  @override
  Future<void> setModificationTime(String path, DateTime modifiedTime) async {
    await _withFdRetry(() async {
      final targetPath = resolvePath(path);
      final entityType = FileSystemEntity.typeSync(targetPath);

      if (entityType == FileSystemEntityType.notFound) {
        throw FileSystemException(
            "Target not found for modification time update: $path (resolved to $targetPath)");
      }

      final fileHandle = File(targetPath);
      await fileHandle.setLastModified(modifiedTime);
    });
  }

  Future<T> _withFdRetry<T>(FutureOr<T> Function() action) async {
    for (int attempt = 1; attempt <= _maxFdRetries; attempt++) {
      try {
        return await Future.sync(action);
      } on FileSystemException catch (e) {
        final bool isFdExhausted = e.osError?.errorCode == 24;
        final bool hasRetry = attempt < _maxFdRetries;
        if (isFdExhausted && hasRetry) {
          await Future.delayed(_fdRetryDelay);
          continue;
        }
        rethrow;
      }
    }

    // Should never reach here, loop either returns or rethrows
    return await Future.sync(action);
  }
}
