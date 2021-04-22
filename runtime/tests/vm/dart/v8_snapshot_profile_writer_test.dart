// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:expect/expect.dart';
import 'package:native_stack_traces/elf.dart';
import 'package:path/path.dart' as path;
import 'package:vm_snapshot_analysis/v8_profile.dart';

import 'use_flag_test_helper.dart';

// Used to ensure we don't have multiple equivalent calls to test.
final _seenDescriptions = <String>{};

Snapshot testProfile(String profilePath) {
  final profile =
      Snapshot.fromJson(jsonDecode(File(profilePath).readAsStringSync()));

  // Verify that there are no "unknown" nodes. These are emitted when we see a
  // reference to an some object but no other metadata about the object was
  // recorded. We should at least record the type for every object in the
  // graph (in some cases the shallow size can legitimately be 0, e.g. for
  // "base objects" not written to the snapshot or artificial nodes).
  for (final node in profile.nodes) {
    Expect.notEquals("Unknown", node.type, "unknown node ${node}");
  }

  final root = profile.nodeAt(0);
  final reachable = <Node>{};

  // HeapSnapshotWorker.HeapSnapshot.calculateDistances (from HeapSnapshot.js)
  // assumes that the graph root has at most one edge to any other node
  // (most likely an oversight).
  for (final edge in root.edges) {
    Expect.isTrue(
        reachable.add(edge.target),
        "root\n\n$root\n\nhas multiple edges to node\n\n${edge.target}:\n\n"
        "${root.edges.where((e) => e.target == edge.target).toList()}");
  }

  // Check that all other nodes are reachable from the root.
  final stack = <Node>[...reachable];
  while (!stack.isEmpty) {
    final next = stack.removeLast();
    for (final edge in next.edges) {
      if (reachable.add(edge.target)) {
        stack.add(edge.target);
      }
    }
  }

  final unreachable =
      profile.nodes.skip(1).where((Node n) => !reachable.contains(n)).toSet();
  Expect.isEmpty(unreachable);

  return profile;
}

Future<void> testJIT(String dillPath) async {
  final description = 'jit';
  Expect.isTrue(_seenDescriptions.add(description),
      "test configuration $description would be run multiple times");

  await withTempDir('v8-snapshot-profile-$description', (String tempDir) async {
    // Generate the snapshot profile.
    final profilePath = path.join(tempDir, 'profile.heapsnapshot');
    final vmTextPath = path.join(tempDir, 'vm_instructions.bin');
    final isolateTextPath = path.join(tempDir, 'isolate_instructions.bin');
    final vmDataPath = path.join(tempDir, 'vm_data.bin');
    final isolateDataPath = path.join(tempDir, 'isolate_data.bin');

    await run(genSnapshot, <String>[
      '--snapshot-kind=core-jit',
      '--vm_snapshot_instructions=$vmTextPath',
      '--isolate_snapshot_instructions=$isolateTextPath',
      '--vm_snapshot_data=$vmDataPath',
      '--isolate_snapshot_data=$isolateDataPath',
      "--write-v8-snapshot-profile-to=$profilePath",
      dillPath,
    ]);

    print("Snapshot profile generated at $profilePath.");

    final profile = testProfile(profilePath);

    // Verify that the total size of the snapshot text and data sections is
    // the same as the sum of the shallow sizes of all objects in the profile.
    // This ensures that all bytes are accounted for in some way.
    final actualSize = await File(vmTextPath).length() +
        await File(isolateTextPath).length() +
        await File(vmDataPath).length() +
        await File(isolateDataPath).length();
    final expectedSize =
        profile.nodes.fold<int>(0, (size, n) => size + n.selfSize);

    Expect.equals(expectedSize, actualSize, "failed on $description snapshot");
  });
}

Future<void> testAOT(String dillPath,
    {bool useAsm = false,
    bool useBare = true,
    bool forceDrops = false,
    bool useDispatch = true,
    bool stripUtil = false, // Note: forced true if useAsm.
    bool stripFlag = false,
    bool disassemble = false}) async {
  if (const bool.fromEnvironment('dart.vm.product') && disassemble) {
    Expect.isFalse(disassemble, 'no use of disassembler in PRODUCT mode');
  }

  // For assembly, we can't test the sizes of the snapshot sections, since we
  // don't have a Mach-O reader for Mac snapshots and for ELF, the assembler
  // merges the text/data sections and the VM/isolate section symbols may not
  // have length information. Thus, we force external stripping so we can test
  // the approximate size of the stripped snapshot.
  if (useAsm) {
    stripUtil = true;
  }

  final descriptionBuilder = StringBuffer()..write(useAsm ? 'assembly' : 'elf');
  if (!useBare) {
    descriptionBuilder.write('-nonbare');
  }
  if (forceDrops) {
    descriptionBuilder.write('-dropped');
  }
  if (!useDispatch) {
    descriptionBuilder.write('-nodispatch');
  }
  if (stripFlag) {
    descriptionBuilder.write('-intstrip');
  }
  if (stripUtil) {
    descriptionBuilder.write('-extstrip');
  }
  if (disassemble) {
    descriptionBuilder.write('-disassembled');
  }

  final description = descriptionBuilder.toString();
  Expect.isTrue(_seenDescriptions.add(description),
      "test configuration $description would be run multiple times");

  await withTempDir('v8-snapshot-profile-$description', (String tempDir) async {
    // Generate the snapshot profile.
    final profilePath = path.join(tempDir, 'profile.heapsnapshot');
    final snapshotPath = path.join(tempDir, 'test.snap');
    final commonSnapshotArgs = [
      if (stripFlag) '--strip', //  gen_snapshot specific and not a VM flag.
      useBare ? '--use-bare-instructions' : '--no-use-bare-instructions',
      "--write-v8-snapshot-profile-to=$profilePath",
      if (forceDrops) ...[
        '--dwarf-stack-traces',
        '--no-retain-function-objects',
        '--no-retain-code-objects'
      ],
      useDispatch ? '--use-table-dispatch' : '--no-use-table-dispatch',
      if (disassemble) '--disassemble', // Not defined in PRODUCT mode.
      dillPath,
    ];

    if (useAsm) {
      final assemblyPath = path.join(tempDir, 'test.S');

      await run(genSnapshot, <String>[
        '--snapshot-kind=app-aot-assembly',
        '--assembly=$assemblyPath',
        ...commonSnapshotArgs,
      ]);

      await assembleSnapshot(assemblyPath, snapshotPath);
    } else {
      await run(genSnapshot, <String>[
        '--snapshot-kind=app-aot-elf',
        '--elf=$snapshotPath',
        ...commonSnapshotArgs,
      ]);
    }

    print("Snapshot generated at $snapshotPath.");
    print("Snapshot profile generated at $profilePath.");

    final profile = testProfile(profilePath);

    final expectedSize =
        profile.nodes.fold<int>(0, (size, n) => size + n.selfSize);

    var checkedSize = false;
    if (!useAsm) {
      // Verify that the total size of the snapshot text and data sections is
      // the same as the sum of the shallow sizes of all objects in the profile.
      // This ensures that all bytes are accounted for in some way.
      final elf = Elf.fromFile(snapshotPath);
      Expect.isNotNull(elf);
      elf!; // To refine type to non-nullable version.

      final vmTextSectionSymbol = elf.dynamicSymbolFor(vmSymbolName);
      Expect.isNotNull(vmTextSectionSymbol);
      final vmDataSectionSymbol = elf.dynamicSymbolFor(vmDataSymbolName);
      Expect.isNotNull(vmDataSectionSymbol);
      final isolateTextSectionSymbol = elf.dynamicSymbolFor(isolateSymbolName);
      Expect.isNotNull(isolateTextSectionSymbol);
      final isolateDataSectionSymbol =
          elf.dynamicSymbolFor(isolateDataSymbolName);
      Expect.isNotNull(isolateDataSectionSymbol);

      final actualSize = vmTextSectionSymbol!.size +
          vmDataSectionSymbol!.size +
          isolateTextSectionSymbol!.size +
          isolateDataSectionSymbol!.size;

      Expect.equals(
          expectedSize, actualSize, "failed on $description snapshot");
      checkedSize = true;
    }

    if (stripUtil || stripFlag) {
      var strippedSnapshotPath = snapshotPath;
      if (stripUtil) {
        strippedSnapshotPath = snapshotPath + '.stripped';
        await stripSnapshot(snapshotPath, strippedSnapshotPath,
            forceElf: !useAsm);
        print("Stripped snapshot generated at $strippedSnapshotPath.");
      }

      // Verify that the actual size of the stripped snapshot is close to the
      // sum of the shallow sizes of all objects in the profile. They will not
      // be exactly equal because of global headers and padding.
      final actualSize = await File(strippedSnapshotPath).length();

      // See Elf::kPages in runtime/vm/elf.h, which is also used for assembly
      // padding.
      final segmentAlignment = 16 * 1024;
      // Not every byte is accounted for by the snapshot profile, and data and
      // instruction segments are padded to an alignment boundary.
      final tolerance = 0.03 * actualSize + 2 * segmentAlignment;

      Expect.approxEquals(expectedSize, actualSize, tolerance,
          "failed on $description snapshot");
      checkedSize = true;
    }

    Expect.isTrue(checkedSize, "no snapshot size checks were performed");
  });
}

Match? matchComplete(RegExp regexp, String line) {
  Match? match = regexp.firstMatch(line);
  if (match == null) return match;
  if (match.start != 0 || match.end != line.length) return null;
  return match;
}

// All fields of "Raw..." classes defined in "raw_object.h" must be included in
// the giant macro in "raw_object_fields.cc". This function attempts to check
// that with some basic regexes.
testMacros() async {
  const String className = "([a-z0-9A-Z]+)";
  const String rawClass = "Raw$className";
  const String fieldName = "([a-z0-9A-Z_]+)";

  final Map<String, Set<String>> fields = {};

  final String rawObjectFieldsPath =
      path.join(sdkDir, 'runtime', 'vm', 'raw_object_fields.cc');
  final RegExp fieldEntry = RegExp(" *F\\($className, $fieldName\\) *\\\\?");

  await for (String line in File(rawObjectFieldsPath)
      .openRead()
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(LineSplitter())) {
    Match? match = matchComplete(fieldEntry, line);
    if (match != null) {
      fields
          .putIfAbsent(match.group(1)!, () => Set<String>())
          .add(match.group(2)!);
    }
  }

  final RegExp classStart = RegExp("class $rawClass : public $rawClass {");
  final RegExp classEnd = RegExp("}");
  final RegExp field = RegExp("  $rawClass. +$fieldName;.*");

  final String rawObjectPath =
      path.join(sdkDir, 'runtime', 'vm', 'raw_object.h');

  String? currentClass;
  bool hasMissingFields = false;
  await for (String line in File(rawObjectPath)
      .openRead()
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(LineSplitter())) {
    Match? match = matchComplete(classStart, line);
    if (match != null) {
      currentClass = match.group(1);
      continue;
    }

    match = matchComplete(classEnd, line);
    if (match != null) {
      currentClass = null;
      continue;
    }

    match = matchComplete(field, line);
    if (match != null && currentClass != null) {
      if (fields[currentClass] == null) {
        hasMissingFields = true;
        print("$currentClass is missing entirely.");
        continue;
      }
      if (!fields[currentClass]!.contains(match.group(2)!)) {
        hasMissingFields = true;
        print("$currentClass is missing ${match.group(2)!}.");
      }
    }
  }

  if (hasMissingFields) {
    Expect.fail("$rawObjectFieldsPath is missing some fields. "
        "Please update it to match $rawObjectPath.");
  }
}

main() async {
  void printSkip(String description) =>
      print('Skipping $description for ${path.basename(buildDir)} '
              'on ${Platform.operatingSystem}' +
          (clangBuildToolsDir == null ? ' without //buildtools' : ''));

  // We don't have access to the SDK on Android.
  if (Platform.isAndroid) {
    printSkip('all tests');
    return;
  }

  await testMacros();

  await withTempDir('v8-snapshot-profile-writer', (String tempDir) async {
    // We only need to generate the dill file once for all JIT tests.
    final _thisTestPath = path.join(sdkDir, 'runtime', 'tests', 'vm', 'dart',
        'v8_snapshot_profile_writer_test.dart');
    final jitDillPath = path.join(tempDir, 'jit_test.dill');
    await run(genKernel, <String>[
      '--platform',
      platformDill,
      ...Platform.executableArguments.where((arg) =>
          arg.startsWith('--enable-experiment=') ||
          arg == '--sound-null-safety' ||
          arg == '--no-sound-null-safety'),
      '-o',
      jitDillPath,
      _thisTestPath
    ]);

    // We only need to generate the dill file once for all AOT tests.
    final aotDillPath = path.join(tempDir, 'aot_test.dill');
    await run(genKernel, <String>[
      '--aot',
      '--platform',
      platformDill,
      ...Platform.executableArguments.where((arg) =>
          arg.startsWith('--enable-experiment=') ||
          arg == '--sound-null-safety' ||
          arg == '--no-sound-null-safety'),
      '-o',
      aotDillPath,
      _thisTestPath
    ]);

    // Just as a reminder for AOT tests:
    // * If useAsm is true, then stripUtil is forced (as the assembler may add
    //   extra information that needs stripping), so no need to specify
    //   stripUtil for useAsm tests.

    // Test profile generation with a core JIT snapshot.
    await testJIT(jitDillPath);

    // Test unstripped ELF generation directly.
    await testAOT(aotDillPath);
    await testAOT(aotDillPath, useBare: false);
    await testAOT(aotDillPath, forceDrops: true);
    await testAOT(aotDillPath, forceDrops: true, useBare: false);
    await testAOT(aotDillPath, forceDrops: true, useDispatch: false);
    await testAOT(aotDillPath,
        forceDrops: true, useDispatch: false, useBare: false);

    // Test flag-stripped ELF generation.
    await testAOT(aotDillPath, stripFlag: true);
    await testAOT(aotDillPath, useBare: false, stripFlag: true);

    // Since we can't force disassembler support after the fact when running
    // in PRODUCT mode, skip any --disassemble tests. Do these tests last as
    // they have lots of output and so the log will be truncated.
    if (!const bool.fromEnvironment('dart.vm.product')) {
      // Regression test for dartbug.com/41149.
      await testAOT(aotDillPath, useBare: false, disassemble: true);
    }

    // We neither generate assembly nor have a stripping utility on Windows.
    if (Platform.isWindows) {
      printSkip('external stripping and assembly tests');
      return;
    }

    // The native strip utility on Mac OS X doesn't recognize ELF files.
    if (Platform.isMacOS && clangBuildToolsDir == null) {
      printSkip('ELF external stripping test');
    } else {
      // Test unstripped ELF generation that is then externally stripped.
      await testAOT(aotDillPath, stripUtil: true);
      await testAOT(aotDillPath, stripUtil: true, useBare: false);
    }

    // TODO(sstrickl): Currently we can't assemble for SIMARM64 on MacOSX.
    // For example, the test runner still uses blobs for
    // dartkp-mac-*-simarm64. Change assembleSnapshot and remove this check
    // when we can.
    if (Platform.isMacOS && buildDir.endsWith('SIMARM64')) {
      printSkip('assembly tests');
      return;
    }
    // Test unstripped assembly generation that is then externally stripped.
    await testAOT(aotDillPath, useAsm: true);
    await testAOT(aotDillPath, useAsm: true, useBare: false);
    // Test stripped assembly generation that is then externally stripped.
    await testAOT(aotDillPath, useAsm: true, stripFlag: true);
    await testAOT(aotDillPath, useAsm: true, stripFlag: true, useBare: false);
  });
}
