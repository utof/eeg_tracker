// Counts the files the code under test opens for reading on THIS isolate (DECISIONS 620-629: "heavy work on the
// screen's thread"). Every `File` made while it is installed (also those `Directory.listSync` hands out) is wrapped;
// each readAsString / readAsBytes / readAsLines / open / openRead counts as one read of that path. Work sent to
// another isolate (Isolate.run) is not seen, which is the point: a read counted here is a read on the screen's thread.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The reads seen, by path.
class ReadCounts {
  final Map<String, int> byPath = {};

  int get total => byPath.values.fold(0, (a, b) => a + b);

  /// Reads of paths containing [part] (a folder such as `/nights/`, or a suffix).
  int of(String part) => byPath.entries.where((e) => e.key.contains(part)).fold(0, (a, e) => a + e.value);

  void clear() => byPath.clear();

  void _hit(String path) => byPath[path] = (byPath[path] ?? 0) + 1;

  @override
  String toString() => 'ReadCounts(total $total: $byPath)';
}

final class _Counting extends IOOverrides {
  _Counting(this.counts);
  final ReadCounts counts;

  @override
  File createFile(String path) => _CountingFile(super.createFile(path), counts);

  // A folder's listing comes from the VM, not from File(): its files are wrapped here.
  @override
  Directory createDirectory(String path) => _CountingDirectory(super.createDirectory(path), counts);
}

FileSystemEntity _wrap(FileSystemEntity e, ReadCounts counts) => e is File && e is! _CountingFile
    ? _CountingFile(e, counts)
    : e is Directory && e is! _CountingDirectory
    ? _CountingDirectory(e, counts)
    : e;

class _CountingDirectory implements Directory {
  _CountingDirectory(this._d, this._counts);
  final Directory _d;
  final ReadCounts _counts;

  @override
  String get path => _d.path;
  @override
  Uri get uri => _d.uri;
  @override
  bool get isAbsolute => _d.isAbsolute;
  @override
  Directory get absolute => _d.absolute;
  @override
  Directory get parent => _d.parent;
  @override
  Future<bool> exists() => _d.exists();
  @override
  bool existsSync() => _d.existsSync();
  @override
  Future<FileStat> stat() => _d.stat();
  @override
  FileStat statSync() => _d.statSync();
  @override
  Future<Directory> create({bool recursive = false}) => _d.create(recursive: recursive);
  @override
  void createSync({bool recursive = false}) => _d.createSync(recursive: recursive);
  @override
  Future<Directory> createTemp([String? prefix]) => _d.createTemp(prefix);
  @override
  Directory createTempSync([String? prefix]) => _d.createTempSync(prefix);
  @override
  Future<String> resolveSymbolicLinks() => _d.resolveSymbolicLinks();
  @override
  String resolveSymbolicLinksSync() => _d.resolveSymbolicLinksSync();
  @override
  Future<Directory> rename(String newPath) => _d.rename(newPath);
  @override
  Directory renameSync(String newPath) => _d.renameSync(newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => _d.delete(recursive: recursive);
  @override
  void deleteSync({bool recursive = false}) => _d.deleteSync(recursive: recursive);
  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) =>
      _d.list(recursive: recursive, followLinks: followLinks).map((e) => _wrap(e, _counts));
  @override
  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) => [
    for (final e in _d.listSync(recursive: recursive, followLinks: followLinks)) _wrap(e, _counts),
  ];
  @override
  Stream<FileSystemEvent> watch({int events = FileSystemEvent.all, bool recursive = false}) =>
      _d.watch(events: events, recursive: recursive);
  @override
  String toString() => _d.toString();
}

/// Installs the counter for the rest of the test (removed in tearDown); returns it.
ReadCounts countReads(void Function(void Function()) addTearDown) {
  final counts = ReadCounts();
  final before = IOOverrides.current;
  IOOverrides.global = _Counting(counts);
  addTearDown(() => IOOverrides.global = before is _Counting ? null : before);
  return counts;
}

/// Runs [body] with the counter installed only inside it.
T countingReads<T>(ReadCounts counts, T Function() body) => IOOverrides.runWithIOOverrides(body, _Counting(counts));

class _CountingFile implements File {
  _CountingFile(this._f, this._counts);
  final File _f;
  final ReadCounts _counts;

  void _read() => _counts._hit(_f.path);

  @override
  String get path => _f.path;
  @override
  Uri get uri => _f.uri;
  @override
  bool get isAbsolute => _f.isAbsolute;
  @override
  File get absolute => _f.absolute;
  @override
  Directory get parent => _f.parent;
  @override
  Future<bool> exists() => _f.exists();
  @override
  bool existsSync() => _f.existsSync();
  @override
  Future<FileStat> stat() => _f.stat();
  @override
  FileStat statSync() => _f.statSync();
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) =>
      _f.create(recursive: recursive, exclusive: exclusive);
  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      _f.createSync(recursive: recursive, exclusive: exclusive);
  @override
  Future<File> rename(String newPath) => _f.rename(newPath);
  @override
  File renameSync(String newPath) => _f.renameSync(newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => _f.delete(recursive: recursive);
  @override
  void deleteSync({bool recursive = false}) => _f.deleteSync(recursive: recursive);
  @override
  Future<File> copy(String newPath) => _f.copy(newPath);
  @override
  File copySync(String newPath) => _f.copySync(newPath);
  @override
  Future<int> length() => _f.length();
  @override
  int lengthSync() => _f.lengthSync();
  @override
  Future<DateTime> lastAccessed() => _f.lastAccessed();
  @override
  DateTime lastAccessedSync() => _f.lastAccessedSync();
  @override
  Future<dynamic> setLastAccessed(DateTime time) => _f.setLastAccessed(time);
  @override
  void setLastAccessedSync(DateTime time) => _f.setLastAccessedSync(time);
  @override
  Future<DateTime> lastModified() => _f.lastModified();
  @override
  DateTime lastModifiedSync() => _f.lastModifiedSync();
  @override
  Future<dynamic> setLastModified(DateTime time) => _f.setLastModified(time);
  @override
  void setLastModifiedSync(DateTime time) => _f.setLastModifiedSync(time);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    if (mode == FileMode.read) _read();
    return _f.open(mode: mode);
  }

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    if (mode == FileMode.read) _read();
    return _f.openSync(mode: mode);
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    _read();
    return _f.openRead(start, end);
  }

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      _f.openWrite(mode: mode, encoding: encoding);
  @override
  Future<Uint8List> readAsBytes() {
    _read();
    return _f.readAsBytes();
  }

  @override
  Uint8List readAsBytesSync() {
    _read();
    return _f.readAsBytesSync();
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    _read();
    return _f.readAsString(encoding: encoding);
  }

  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    _read();
    return _f.readAsStringSync(encoding: encoding);
  }

  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) {
    _read();
    return _f.readAsLines(encoding: encoding);
  }

  @override
  List<String> readAsLinesSync({Encoding encoding = utf8}) {
    _read();
    return _f.readAsLinesSync(encoding: encoding);
  }

  @override
  Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) =>
      _f.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  void writeAsBytesSync(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) =>
      _f.writeAsBytesSync(bytes, mode: mode, flush: flush);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => _f.writeAsString(contents, mode: mode, encoding: encoding, flush: flush);
  @override
  void writeAsStringSync(String contents, {FileMode mode = FileMode.write, Encoding encoding = utf8, bool flush = false}) =>
      _f.writeAsStringSync(contents, mode: mode, encoding: encoding, flush: flush);
  @override
  Future<String> resolveSymbolicLinks() => _f.resolveSymbolicLinks();
  @override
  String resolveSymbolicLinksSync() => _f.resolveSymbolicLinksSync();
  @override
  Stream<FileSystemEvent> watch({int events = FileSystemEvent.all, bool recursive = false}) =>
      _f.watch(events: events, recursive: recursive);
  @override
  String toString() => _f.toString();
}
