// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.9

library PrefixTest;

import "package:expect/expect.dart";
import "new_test1.dart";

main() {
  Expect.equals(Prefix.getSource(), Prefix.getImport() + 1);
}
