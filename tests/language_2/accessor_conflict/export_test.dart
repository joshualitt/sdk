// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.9

// Verify that a getter and its corresponding setter can be imported from two
// different files via a common export.  In this test the getter is imported
// first.

import "package:expect/expect.dart";

import "export_helper.dart";

main() {
  getValue = 123;
  Expect.equals(x, 123);
  x = 456;
  Expect.equals(setValue, 456);
}
