// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.9

// Test that class with a cyclic hierarchy doesn't cause a loop in dart2js.

class A
//    ^
// [analyzer] COMPILE_TIME_ERROR.RECURSIVE_INTERFACE_INHERITANCE
// [cfe] 'A' is a supertype of itself.
    extends A
{
  // When checking that foo isn't overriding an instance method in the
  // superclass, dart2js might loop.
  static foo() {}
}

main() {
  new A();
}
