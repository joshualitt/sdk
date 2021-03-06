// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.9

import 'dart:mirrors';
import 'empty.dart';

main() {
  var empty = currentMirrorSystem().findLibrary(#empty);
  print(empty.location); // Used to crash VM.
}
