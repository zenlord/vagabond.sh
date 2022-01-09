#!/bin/bash
# @@ VAGABOND @@
# Script to sync $HOME upon login and logout via GDM scripts or via pam_script
#  Syncs to rsync daemon on server.domain if on LAN - uses ssh tunnel if on WAN
#  Requires rsync, ssh, awk, echo, grep, cat, head, cut, mkdir, chown and netcat-bsd
#  SSH tunnel requires that the client has an SSH key and
#    that that key is trusted by the root user on the server.domain

## The script can be run in the root crontab or a systemd timer (just replace $4 with 'auto_from_tmp')

RSYNC_PORT=873
#RSYNC_OPTS=("-azx" "--delete-delay" "--max-size=15m" "--include='*/'" "--exclude-from=/usr/local/bin/vagabond.excludes" "--human-readable")
#RSYNC_OPTS=("--dry-run" "-azx" "--delete-delay" "--max-size=15m" "--include='*/'" "--exclude-from=/usr/local/bin/vagabond.excludes" "--human-readable")
RSYNC_OPTS=("-azx" "--max-size=15m" "--include='*/'" "--exclude-from=/usr/local/bin/vagabond.excludes" "--human-readable")
SSH_PORT=17122
SSH_KEY="/root/.ssh/rsyncd.ed25519"
## No trailing slash!
HOMEDIR="/home"

RSYNC="/usr/bin/rsync"
SSH="/usr/bin/ssh"
NC="/usr/bin/nc -z -w 1"
AWK="/usr/bin/awk"
MKDIR="/usr/bin/mkdir"
CHOWN="/usr/bin/chown"
SYSTEMD_CAT="/usr/bin/systemd-cat"

SCRIPT_NAME=$(basename "$0")
DIRECTION="$1"
SERVER="$2"
MODULE="$3"
SUBDIR="$4"
FORCE="$5"


##
## USAGE(): show the user how to use vagabond.sh
##
usage () {
  cat <<HELP_USAGE
Error:
  $1

Usage:
  $SCRIPT_NAME push|pull server.domain rsync_module user [rsync|ssh|'']

Parameters:
  * param1 (DIRECTION) must be either "push" or "pull"
  * param2 (RSYNC HOST)
  * param3 (RSYNC MODULE)
  * param4 (USERNAME) if this is equal to 'auto_from_tmp', the username is read from /tmp/vagabond.sh_user
  * param5 (FORCE RSYNC MODE) is optional: add "rsync" or "ssh" (for testing purposes e.g.)
HELP_USAGE

  exit 1;
}

[[ "$#" =~ ^(4|5)$ ]] || { usage "This script expects to be passed exactly 4 or 5 parameters."; }
[[ "$1" =~ ^(push|pull)$ ]] || { usage "The second parameter should be either 'push' or 'pull'"; }
[[ "$5" =~ ^(rsync|ssh|'')$ ]] || { usage "The fifth parameter should be either 'rsync', 'ssh' or empty"; }

##
## LOG() and EXITLOG: logging to journal
##
log () {
  echo "$2" | $SYSTEMD_CAT -t $SCRIPT_NAME -p $1
}

exitlog () {
  echo "---" | $SYSTEMD_CAT -t $SCRIPT_NAME
  exit "$1"
}

##
## SET_USER_IN_TMP() and CLEAR_USER_FROM_TMP: Set/Clear the username in/from a temporary file
##
set_user_in_tmp () {
  echo "$1" > /tmp/vagabond.sh_user
}

clear_user_from_tmp () {
  echo "" > /tmp/vagabond.sh_user
}

##
## get_address(): Find the ip address of the server to connect to
##
get_address () {
  IPv4=$(getent ahostsv4 "$1" | grep STREAM | head -n 1 | cut -d ' ' -f 1);
  IPv6=$(getent ahostsv6 "$1" | grep STREAM | head -n 1 | cut -d ' ' -f 1);

  if [[ "$IPv4" == 2 && "$IPv6" == 2 ]]; then
    log alert "Hostname cannot be resolved. Exiting.";
    exitlog 1;
  fi

  if [[ "$IPv4" == '127.0.0.1' && "$IPv6" == '::1' ]]; then
    log alert "Script is run from localhost. Exiting.";
    exitlog 1;
  fi

  if [[ "$IPv6" != '::1' ]]; then
    log info "Script found IPv6 address ($IPv6).";
    IP="$IPv6";
  fi

  if [[ "$IPv4" != '127.0.0.1' ]]; then
    log info "Script found IPv4 address ($IPv4).";
    IP="$IPv4";
  fi

  if ! [[ "$IP" ]]; then
    log alert "Script did not find an IP address. Exiting.";
    exitlog 1;
  fi

  log info "Script will use IP address $IP.";
  echo "$IP";
}

##
## RSYNCD_AVAILABLE(): Test whether rsyncd is available
##
rsyncd_available () {
  ## Test connection to port
  $NC $1 $RSYNC_PORT

  if [[ "$?" != 0 ]]; then
    log warning "Script [$NC $1 $RSYNC_PORT] did not find rsync daemon on $1:$RSYNC_PORT.";
    return 1;
  fi

  ## Test connection to rsync daemon
  $RSYNC --contimeout=5 rsync://$1:$RSYNC_PORT 2>/dev/null

  if [[ "$?" != 0 ]]; then
    log warning "Script could not connect to rsync://$1:$RSYNC_PORT.";
    return 1;
  fi

  ## Test connection to module on rsync daemon
  if [[ $($RSYNC --contimeout=5 rsync://$1:$RSYNC_PORT | "$AWK" '{print $1}') != "$2" ]]; then
    log warning "Script did not find module '$2' at rsync://$1:$RSYNC_PORT.";
    return 1;
  fi

  log info "Script found rsync daemon and module on rsync://$1:$RSYNC_PORT/$2.";
  echo 1;
}

##
## SSHD_AVAILABLE(): Test whether sshd is available
##
sshd_available () {
  $NC $1 $SSH_PORT

  if [[ "$?" != 0 ]]; then
    log warning "Script [$NC $1 $SSH_PORT] did not find ssh daemon on $1:$SSH_PORT.";
    return 1;
  fi

  log info "Script found ssh daemon on $1:$SSH_PORT.";
  echo 1;
}

##
## ENSURE_LOCALDIR_EXISTS(): Test whether the local directory is present, and if not, create it
##
ensure_localdir_exists () {
  if ! [[ -d "$HOMEDIR/$1" ]]; then
    log info "Directory $HOMEDIR/$1 does not exist. Attempting to create.";

    $MKDIR --mode=770 $HOMEDIR/$1
    if [[ $? ]]; then
      log info "Directory $HOMEDIR/$1 created succesfully.";

      USERID=$(getent passwd | grep $1 | cut -d ':' -f 3);
      GROUPID=$(getent passwd | grep $1 | cut -d ':' -f 4);
      $CHOWN $USERID:$GROUPID $HOMEDIR/$1

      if [[ $? ]]; then
        log info "Directory $HOMEDIR/$1 chown'ed to $USERID:$GROUPID.";
      else
        log alert "Failed chown'ing dir $HOMEDIR/$1. Exiting.";
        exitlog 1;
      fi

    else
      log alert "Failed creating dir $HOMEDIR/$1. Exiting.";
      exitlog 1;
    fi

  fi
}

##
## SYNC(): Main action
##
sync () {
  START=$(date +%s);
  IP=$(get_address "$1");

  ## Define sync mode - last available one will be used
  if [[ "$5" ]]; then
    log info "Sync mode is explicitly set to '$5'.";
    SYNC_MODE="$5";

    if [[ "$SYNC_MODE" == 'rsync' ]]; then
      if [[ ! $(rsyncd_available "$IP") ]]; then
        log alert "Sync mode 'rsync' not available.";
        exitlog 1;
      fi
    fi

    if [[ "$SYNC_MODE" == 'ssh' ]]; then
      if [[ ! $(sshd_available "$IP") ]]; then
        log alert "Sync mode 'ssh' not available.";
        exitlog 1;
      fi
    fi

  else
    log info "No explicit sync mode set. Will look for available sync modes...";

    if [[ $(rsyncd_available "$IP") ]]; then
      log info "Setting sync mode to rsync...";
      SYNC_MODE='rsync';
    fi

    if [[ $(sshd_available "$IP") ]]; then
      log info "Setting sync mode to ssh...";
      SYNC_MODE='ssh';
    fi
  fi

  ## Fetch $USERNAME from temp file if required (e.g. when run from systemd as root)
  if [[ "$4" == 'auto_from_tmp' ]]; then
    if [[ -f /tmp/vagabond.sh_user ]]; then
      USERNAME=$(cat /tmp/vagabond.sh_user);
    else
      log alert "Systemd timer is run, but no user is logged in.";
      exitlog 1;
    fi
  else
    USERNAME="$4";
  fi

  ## Start sync
  if [[ "$SYNC_MODE" == 'rsync' ]]; then

    log info "Starting insecure rsync daemon mode.";

    if [[ "$2" == 'push' ]]; then
      log info "Starting $2 to $1 ($IP) via rsync over insecure rsync:// protocol.";
      SRC="$HOMEDIR/$USERNAME";
      DEST="$IP::$3";

    elif [[ "$2" == 'pull' ]]; then
      log info "Starting $2 from $1 ($IP) via rsync over insecure rsync:// protocol.";
      SRC="$IP::$3/$USERNAME";
      DEST="$HOMEDIR";
      ensure_localdir_exists "$USERNAME";
      set_user_in_tmp "$USERNAME";
    fi

    RSYNC_OPTIONS="${RSYNC_OPTS[@]}";
    log info "Command to be executed = $RSYNC $RSYNC_OPTIONS $SRC $DEST";
    $RSYNC ${RSYNC_OPTS[@]} $SRC $DEST 2>&1 | $SYSTEMD_CAT -t "$SCRIPT_NAME"

  elif [[ "$SYNC_MODE" == 'ssh' ]]; then

    log info "Starting secure ssh mode.";

    if [[ "$2" == 'push' ]]; then
      log info "Starting $2 to $1 ($IP) via rsync over secure ssh tunnel.";
      SRC="$HOMEDIR/$USERNAME";
      DEST="$IP:$HOMEDIR";

    elif [[ "$2" == 'pull' ]]; then
      log info "Starting $2 from $1 ($IP) via rsync over secure tunnel.";
      SRC="$IP:$HOMEDIR/$USERNAME";
      DEST="$HOMEDIR";
      ensure_localdir_exists "$USERNAME";
      set_user_in_tmp "$USERNAME";
    fi

    RSYNC_OPTIONS="${RSYNC_OPTS[@]}";
    log info "Command to be executed = $RSYNC $RSYNC_OPTIONS -e \"$SSH -p $SSH_PORT -i $SSH_KEY\" $SRC $DEST";
    $RSYNC ${RSYNC_OPTS[@]} -e "$SSH -p $SSH_PORT -i $SSH_KEY" $SRC $DEST 2>&1 | $SYSTEMD_CAT -t "$SCRIPT_NAME"

  else
    log alert "No sync mode available.";
    exitlog 1;
  fi

  if [[ "$?" == 0 ]]; then
    log info "Command completed succesfully (return code $?).";
  else
    log warning "Command failed (return code $?).";
  fi

  END=$(date +%s);
  log info "Sync-script ran for $(( $END-$START )) seconds.";

}

##
## All systems go
##
sync "$SERVER" "$DIRECTION" "$MODULE" "$SUBDIR" "$FORCE";
exitlog 0;
