# vagabond.sh
A wrapper script for rsync to sync $HOME to/from a remote rsync- or ssh-server

# Goal
Solve the issue with roaming profiles with NFS(v4) over WiFi

# Solution
Set up this script to:
* Pull the contents of the remote $HOME to the local $HOME upon login
* Push the contents of the local $HOME to the remote $HOME upon logout/shutdown
* Push the contents of the local $HOME to the remote $HOME every hour

Additionally, this script can be set up to use either ssh or rsync:// - Personally I have set it up to choose rsync:// when the client is on the same LAN as the server: the server's firewall has port 873 open, but the network's firewall drops all connections to port 873.

# See any errors? Want to improve the script?
Create an issue, or better yet, a pull request!
