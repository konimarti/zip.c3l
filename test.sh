#!/bin/sh
# set -x

c3c test 2> /dev/null
./build/testrun

c3c build zipinfo
c3c build zipar
c3c build zipex

zipinfo="./build/zipinfo"
zipar="./build/zipar"
zipex="./build/zipex"
zipfile="/tmp/tmp.zip"

cleanup()
{
	rm $zipfile 2> /dev/null
	rm -r /tmp/resources
}

#
# zip round-trip
#
echo
echo "************************************"
echo "*** (1) zipar / zipex round-trip ***"
echo "************************************"
$zipar $zipfile ./resources/test_zip
$zipinfo $zipfile
$zipex $zipfile /tmp
diff -sr resources/test_zip /tmp/resources/test_zip
cleanup

#
# Validate zipex against zip -r6
#
echo
echo "**************************************"
echo "*** (2) zip -r6 / zipex round-trip ***"
echo "**************************************"
zip -r6 $zipfile ./resources/test_zip
$zipex $zipfile /tmp
diff -sr resources/test_zip /tmp/resources/test_zip
cleanup

#
# Validate zipar against unzip
#
echo
echo "************************************"
echo "*** (3) zipar / unzip round-trip ***"
echo "************************************"
$zipar $zipfile ./resources/test_zip
unzip $zipfile -d /tmp
diff -sr resources/test_zip /tmp/resources/test_zip
cleanup
