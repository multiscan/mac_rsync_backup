#!/bin/bash

laconf="$HOME/Library/LaunchAgents/rsync_backup.plist"
name="rsync_backup"

casa="$(cd $(dirname $0); pwd)"
CONFIGS=$(cd $casa/config ; /bin/ls *.yml)

cmd="$casa/$(basename $0)"
bkpcmd="ruby $(cd $(dirname $0); pwd)/$(basename $0 _cron.sh).rb"

die() {
  echo "! $*" >&2
  exit 1
}

# ------------------------------------------------------------- init

check_cron() {
  if [ ! -f $laconf ] ; then
    cat > $laconf <<-____EOF
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>$name</string>
        <key>ProgramArguments</key>
        <array>
          <string>sh</string>
          <string>-c</string>
          <string>$cmd</string>
        </array>
        <key>StartInterval</key> 
        <integer>1800</integer>
      </dict>
      </plist>    
____EOF
  fi
  launchctl list | grep -q "$name"  || launchctl load -w $laconf
}

status() {
  check_cron
  if launchctl list | grep -q "$name" ; then 
    c="configured"
  else
    c="not configured"
  fi
  echo "$c"
}

start() {
  launchctl start $name
  sleep 2
  status
}

stop() {
  echo "Stopping..."
  launchctl stop $name
  sleep 2
  status
}

restart() {
  stop
  sleep 2
  start
}

reconfigure() {
  stop
  sleep 2
  echo "Unregistering $name service"
  launchctl remove $name
  rm -f $laconf
  sleep 2
  echo "Registering $name service"
  sleep 2
  check_cron
  status
}

run_backup() {
  for c in $CONFIGS ; do
    $bkpcmd $c
  done
}

case $1 in 
  start)       start   ; ;;
  stop)        stop    ; ;;
  restart)     restart ; ;;
  reconfigure) reconfigure; ;;
  status)      status; ;;
  *)           run_backup ; ;;
esac
