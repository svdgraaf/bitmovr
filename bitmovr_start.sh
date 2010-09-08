#!/bin/bash
#
# The actual start-up script of bitmovr
#

if [ -f /etc/bitmovr/bitmovr.conf ]; then
  . /etc/bitmovr/bitmovr.conf
else
  echo "No configfile found, exit."
  exit 1
fi

# Generate backend-includefile for nginx

  echo "# This file is generated by Bitmover init script, will be overwritten" > $backendfile
  echo "# each time the bitmover is restarted, so make no changes here" >> $backendfile
  echo "upstream backend { " >> $backendfile

  counter=0
  while [ $counter -ne $serverCount ]
  do
    $lua $bitmovrlua $bind:$port &
    echo "  server $bind:$port;" >> $backendfile

    counter=$(( $counter + 1 ))
    port=$(( $port + 1 ))
  done
  echo "}" >> $backendfile

  # special bitmover for encoding.com
  $lua $bitmovrlua $bind:60000 &

# After this, you need to restart nginx (reload) to use the new proxys
# reload is done through the init-script

