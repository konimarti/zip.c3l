#!/bin/sh
set -x

c3c test 2> /dev/null
./build/testrun

c3c build zipinfo
c3c build zipar
c3c build zipex

zipinfo="./build/zipinfo"
zipar="./build/zipar"
zipex="./build/zipex"
zipfile="/tmp/tmp.zip"

#set -e

#
# zip round-trip
#

# run test
$zipar $zipfile ./resources/test_zip
$zipinfo $zipfile
$zipex $zipfile /tmp
diff -sr resources/test_zip /tmp/test_zip

# cleanup
rm $zipfile
rm -r /tmp/test_zip

#
# Validate zipex against zip -r6
#

# run test
zip -r6 $zipfile ./resources/test_zip
$zipex $zipfile /tmp
diff -sr resources/test_zip /tmp/resources/test_zip

# cleanup
rm $zipfile
rm -r /tmp/resources/test_zip

#
# Validate zipar against unzip
#

# run test
$zipar $zipfile ./resources/test_zip
unzip $zipfile -d /tmp
diff -sr resources/test_zip /tmp/test_zip

# cleanup
rm $zipfile
rm -r /tmp/test_zip
