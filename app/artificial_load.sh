#!/bin/bash

COUNTER=0

while [  $COUNTER -lt 10000 ] ;
do
 curl -s localhost:8081 > /dev/null
 curl -s localhost:8081/owners/find > /dev/null
 curl -s localhost:8081/owners?lastName= > /dev/null
 curl -s localhost:8081/owners/1 > /dev/null
 curl -s localhost:8081/owners/4 > /dev/null
 curl -s localhost:8081/owners/6 > /dev/null
 curl -s localhost:8081/owners/8 > /dev/null
 curl -s localhost:8081/vets.html > /dev/null
 curl -s localhost:8081/oups > /dev/null
 let COUNTER=COUNTER+1
done

