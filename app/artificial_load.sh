#!/bin/bash

COUNTER=0

while [  $COUNTER -lt 10000 ] ;
do
 curl -s localhost > /dev/null
 curl -s localhost/owners/find > /dev/null
 curl -s localhost/owners?lastName= > /dev/null
 curl -s localhost/owners/1 > /dev/null
 curl -s localhost/owners/4 > /dev/null
 curl -s localhost/owners/6 > /dev/null
 curl -s localhost/owners/8 > /dev/null
 curl -s localhost/vets.html > /dev/null
 curl -s localhost/oups > /dev/null
 let COUNTER=COUNTER+1
done

