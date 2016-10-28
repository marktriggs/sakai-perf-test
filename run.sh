#!/bin/bash

cd "`dirname "$0"`"

export JAVA_OPTS="-Xmx1g -Xms1g"

exec lib/jruby main.rb ${1+"$@"}
