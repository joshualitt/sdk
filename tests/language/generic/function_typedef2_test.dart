// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
// Dart test for a function type test that cannot be eliminated at compile time.

// This test validates the static errors for typedefs in language versions
// prior to the release of nonfunction type aliases (Dart 2.13).
// @dart=2.12

import "package:expect/expect.dart";

class A {}

typedef int F();

typedef G = F;
//        ^
// [analyzer] SYNTACTIC_ERROR.EXPERIMENT_NOT_ENABLED
// [cfe] Can't create typedef from non-function type.
typedef H = int;
//        ^
// [analyzer] SYNTACTIC_ERROR.EXPERIMENT_NOT_ENABLED
// [cfe] Can't create typedef from non-function type.
typedef I = A;
//        ^
// [analyzer] SYNTACTIC_ERROR.EXPERIMENT_NOT_ENABLED
// [cfe] Can't create typedef from non-function type.
typedef J = List<int>;
//        ^
// [analyzer] SYNTACTIC_ERROR.EXPERIMENT_NOT_ENABLED
// [cfe] Can't create typedef from non-function type.
typedef K = Function(Function<A>(A<int>));
//                               ^^^^^^
// [analyzer] COMPILE_TIME_ERROR.WRONG_NUMBER_OF_TYPE_ARGUMENTS
// [cfe] Can't use type arguments with type variable 'A'.
typedef L = Function({x});
//                    ^
// [analyzer] COMPILE_TIME_ERROR.UNDEFINED_CLASS
// [cfe] Type 'x' not found.
//                     ^
// [analyzer] SYNTACTIC_ERROR.MISSING_IDENTIFIER
// [cfe] Expected an identifier, but got '}'.

typedef M = Function({int});
        //               ^
        // [analyzer] SYNTACTIC_ERROR.MISSING_IDENTIFIER
        // [cfe] Expected an identifier, but got '}'.

foo({bool int = false}) {}
main() {
  bool b = true;
  Expect.isFalse(b is L);
  Expect.isFalse(b is M);
  Expect.isTrue(foo is M);
}
