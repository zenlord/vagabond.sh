# vagabond.sh
A wrapper script for rsync to sync $HOME to/from a remote rsync- or ssh-server

# Goal
Solve the issue with roaming user profiles with NFS(v4) over WiFi/WAN (sluggishness)
More info: https://unix.stackexchange.com/questions/682711/centralized-home-for-roaming-devices-sync-instead-of-nfs

Stretch goals:
* Implement alternative sync mechanisms, such as lsync, btrfs-send or zfs-send
* Implement alternative methods to run the script: e.g. pam_script would work with other dm's (or tty's) as well

# Solution
Set up this script to:
* Pull the contents of the remote $HOME to the local $HOME upon login
* Push the contents of the local $HOME to the remote $HOME upon logout/shutdown
* Push the contents of the local $HOME to the remote $HOME every hour

Additionally, this script can be set up to use either ssh or rsync:// - Personally I have set it up to choose rsync:// when the client is on the same LAN as the server: the server's firewall has port 873 open, but the network's firewall drops all connections to port 873.

# Are we reinventing the wheel?
Probably yes: there are other solutions available, like unison, syncthing, nextcloud etc.
But:
* unison is known to be picky of identical versions between server and client, and the goal does not require full bi-directionality
* nextcloud is usually run as part of the startup of a session, but how do you organize the first sync? Right, a script :)

# See any errors? Want to improve the script?
Create an issue, or better yet, a pull request!
