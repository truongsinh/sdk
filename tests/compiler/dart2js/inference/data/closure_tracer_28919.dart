// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Regression test for issue 28919.

/*element: foo1:[null]*/
foo1() {
  final methods = [];
  var res, sum;
  for (int i = 0;
      i /*invoke: [subclass=JSPositiveInt]*/ != 3;
      i /*invoke: [subclass=JSPositiveInt]*/ ++) {
    methods
        . /*invoke: Container([exact=JSExtendableArray], element: [subclass=Closure], length: null)*/ add(
            /*[null]*/ (int /*[exact=JSUInt31]*/ x) {
      res = x;
      sum = x /*invoke: [exact=JSUInt31]*/ + i;
    });
  }
  methods /*Container([exact=JSExtendableArray], element: [subclass=Closure], length: null)*/ [
      0](499);
  probe1res(res);
  probe1sum(sum);
  probe1methods(methods);
}

/*element: probe1res:[null|exact=JSUInt31]*/
probe1res(/*[null|exact=JSUInt31]*/ x) => x;

/*element: probe1sum:[null|subclass=JSPositiveInt]*/
probe1sum(/*[null|subclass=JSPositiveInt]*/ x) => x;

/*element: probe1methods:Container([exact=JSExtendableArray], element: [subclass=Closure], length: null)*/
probe1methods(
        /*Container([exact=JSExtendableArray], element: [subclass=Closure], length: null)*/ x) =>
    x;

/*element: nonContainer:[exact=JSExtendableArray]*/
nonContainer(/*[exact=JSUInt31]*/ choice) {
  var m = choice /*invoke: [exact=JSUInt31]*/ == 0 ? [] : "<String>";
  if (m is! List) throw 123;
  // The union then filter leaves us with a non-container type.
  return m;
}

/*element: foo2:[null]*/
foo2(int /*[exact=JSUInt31]*/ choice) {
  final methods = nonContainer(choice);

  /// ignore: unused_local_variable
  var res, sum;
  for (int i = 0;
      i /*invoke: [subclass=JSPositiveInt]*/ != 3;
      i /*invoke: [subclass=JSPositiveInt]*/ ++) {
    methods. /*invoke: [exact=JSExtendableArray]*/ add(
        /*[null]*/ (int
            /*strong.[null|subclass=Object]*/
            /*omit.[null|subclass=JSInt]*/
            /*strongConst.[null|subclass=Object]*/
            /*omitConst.[null|subclass=JSInt]*/
            x) {
      res = x;
      sum = x /*invoke: [null|subclass=JSInt]*/ + i;
    });
  }
  methods /*[exact=JSExtendableArray]*/ [0](499);
  probe2res(res);
  probe2methods(methods);
}

/*element: probe2res:[null|subclass=JSInt]*/
probe2res(

        /*[null|subclass=JSInt]*/
        x) =>
    x;

/*element: probe2methods:[exact=JSExtendableArray]*/
probe2methods(/*[exact=JSExtendableArray]*/ x) => x;

/*element: main:[null]*/
main() {
  foo1();
  foo2(0);
  foo2(1);
}
