# Mac

Scripts for macOS endpoint management. These run via NinjaOne RMM or directly from a terminal session.

See [HOWTO.md](../HOWTO.md) for guidance on downloading and running scripts.

---

## Table of Contents

- [Scripts](#scripts)
  - [Applications](#applications)
  - [OS](#os)
  - [Security](#security)
- [Command Reference](#command-reference)
  - [Filesystem Operations](#filesystem-operations)
  - [System Functions](#system-functions)
  - [Network Operations](#network-operations)
  - [User Functions](#user-functions)
  - [Mac-Specific Utilities](#mac-specific-utilities)
  - [Resources](#resources)

---

## Scripts

### Applications

| Script | Description |
|---|---|
| [Install BitDefender GravityZone.sh](Applications/Install%20BitDefender%20GravityZone.sh) | Installs the BitDefender GravityZone endpoint agent on macOS |
| [Install ConnectSecure Agent.sh](Applications/Install%20ConnectSecure%20Agent.sh) | Installs the ConnectSecure (CyberCNS) vulnerability scanning agent on macOS |
| [Install Huntress Agent.sh](Applications/Install%20Huntress%20Agent.sh) | Installs the Huntress agent on macOS via NinjaOne |
| [Uninstall Webroot.sh](Applications/Uninstall%20Webroot.sh) | Removes the Webroot SecureAnywhere agent from macOS |

### OS

| Script | Description |
|---|---|
| [Configure Automatic Updates.sh](OS/Configure%20Automatic%20Updates.sh) | Enables or disables automatic macOS software updates |
| [Create Admin User.sh](OS/Create%20Admin%20User.sh) | Creates a local administrator account on macOS |
| [Create Desktop Shortcut.sh](OS/Create%20Desktop%20Shortcut.sh) | Creates a URL shortcut on the user's Desktop |
| [Get Apple IDs.sh](OS/Get%20Apple%20IDs.sh) | Reports Apple IDs associated with accounts on the device |
| [Set User Password.sh](OS/Set%20User%20Password.sh) | Sets the password for a specified local user account |

### Security

| Script | Description |
|---|---|
| [Audit Admin Users.sh](Security/Audit%20Admin%20Users.sh) | Reports all users with administrator privileges on the device |
| [Detect Antivirus.sh](Security/Detect%20Antivirus.sh) | Detects installed/active third-party antivirus or EDR products and falls back to Apple XProtect status; reports to NinjaOne `installedAntivirus` field |
| [Detect CVE CloudMensis.sh](Security/Detect%20CVE%20CloudMensis.sh) | Checks for indicators of the CloudMensis macOS spyware |
| [Detect MDM Enrollment.sh](Security/Detect%20MDM%20Enrollment.sh) | Reports whether the device is enrolled in an MDM platform |
| [Get FileVault Key.sh](Security/Get%20FileVault%20Key.sh) | Retrieves the FileVault recovery key for the device |
| [Get FileVault Status.sh](Security/Get%20FileVault%20Status.sh) | Reports the current FileVault encryption status and publishes it to the diskEncryptionStatus Ninja custom field |

---

## Command Reference

macOS uses the Bash or Zsh shell (Zsh is the default since macOS Catalina). Most Linux/POSIX commands work as-is. This section covers the overlap and highlights what's different or macOS-specific.

Any text after a # in an example is a comment explaining what the command does.

---

# Filesystem Operations

Note: macOS uses forward slashes like Linux. The user home directory is `/Users/username` (not `/home/username`).

## Directories

**Invoke the Terminal**  
`⌘ + Space` → type `Term` → Enter

**Change Directory**
```sh
cd ~            # Go to current user's home directory
cd /Users       # macOS home directories live here (not /home like Linux)
cd /Applications
cd ..           # Go up one level
```

**Create / delete directory**
```sh
mkdir foldername    # Create a directory
rmdir foldername    # Remove an empty directory
rm -rf foldername   # Remove a directory and all its contents (use with care)
```

**Print working directory**
```sh
pwd             # Show current path
```

**List Files**
```sh
ls              # List files
ls -a           # Include hidden dot-files
ls -l           # Long format with permissions and sizes
ls -lh          # Long format with human-readable sizes
ls -G           # Colorized output (macOS default ls flag for color)
```

## File Operations

**View file contents**
```sh
cat filename        # Print file to terminal
less filename       # Paginate: ↑/↓ to scroll, q to quit
tail -f logfile     # Follow a log file in real time
```

**Find**
```sh
find / -name "filename"          # Find a file by name from root
find /Users -name "*.plist"      # Find .plist files under /Users
grep -Ri "search term" /path/    # Case-insensitive content search, recursive
```

**Edit**
```sh
nano filename       # Simple terminal editor: Ctrl+O to save, Ctrl+X to exit
vim filename        # Advanced editor: i to insert, Esc then :wq to save and quit
open filename       # Open file with its default app (macOS-specific)
open -a TextEdit filename  # Open with a specific application
```

**Copy, Move, Delete**
```sh
cp source.txt dest.txt          # Copy file
cp -R sourcefolder destfolder   # Copy folder recursively
mv source.txt /path/dest.txt    # Move or rename a file
rm filename                     # Delete file
rm -rf foldername               # Delete folder and contents
```

**Copy output to clipboard (macOS-specific)**
```sh
command | pbcopy        # Copy command output to clipboard
pbpaste                 # Paste clipboard contents to terminal
cat file.txt | pbcopy   # Copy file contents to clipboard
```

## Disks and Drives
```sh
diskutil list                         # List all disks and partitions
diskutil info /dev/disk0              # Details for a specific disk
diskutil eraseDisk APFS NewName /dev/disk2  # Erase and reformat a disk
df -h                                 # Disk space usage (human-readable)
du -sh /path/to/folder                # Size of a specific folder
```

---

# System Functions

## Operating System Info
```sh
sw_vers                     # macOS version (ProductName, ProductVersion, BuildVersion)
sw_vers -productVersion     # Just the version number, e.g. 14.4.1
system_profiler SPSoftwareDataType  # Detailed OS info
uname -a                    # Kernel version and architecture
```

## System Info
```sh
system_profiler SPHardwareDataType  # Hardware overview: model, CPU, RAM, serial number
system_profiler SPMemoryDataType    # Memory slots and installed RAM
sysctl -n machdep.cpu.brand_string  # CPU model
sysctl -n hw.memsize | awk '{print $1/1073741824 " GB"}'  # Total RAM in GB
```

## Run a command
```sh
sudo command        # Run with elevated privileges (prompts for admin password)
sudo !!             # Re-run the last command with sudo
open -a App.app     # Launch an application from the terminal
```

## Services (LaunchAgents / LaunchDaemons)
```sh
launchctl list                              # List all loaded launch agents/daemons
launchctl list | grep -i servicename        # Search for a specific service
launchctl load /Library/LaunchDaemons/com.example.plist    # Load a service
launchctl unload /Library/LaunchDaemons/com.example.plist  # Unload a service
launchctl start com.example.service         # Start a loaded service
launchctl stop com.example.service          # Stop a loaded service
```

## Process List
```sh
ps aux                  # All processes for all users
ps aux | grep chrome    # Filter for a specific process
top                     # Real-time process viewer (q to quit)
activity monitor        # GUI equivalent: open /Applications/Utilities/Activity\ Monitor.app
```

## Kill
```sh
kill {pid}              # Gracefully stop a process by ID
kill -9 {pid}           # Force-kill a process by ID
killall Finder          # Kill all processes matching a name (restarts Finder)
pkill -i "chrome"       # Case-insensitive process name kill
```

## Stay Awake
```sh
caffeinate              # Keep the Mac awake while the terminal is open
caffeinate -t 3600      # Stay awake for 3600 seconds (1 hour)
```

---

# Network Operations

## What is my LAN IP
```sh
ipconfig getifaddr en0          # IP of the primary Wi-Fi adapter
ipconfig getifaddr en1          # IP of the Ethernet adapter
ifconfig | grep "inet "         # All IPv4 addresses
```

## What is my WAN IP
```sh
curl -s https://ifconfig.me
curl -s https://api.ipify.org
```

## Domain Name Lookup and DNS Records
```sh
dig google.com              # DNS A record lookup
dig google.com MX           # MX records
dig google.com TXT          # TXT/SPF records
dig -x 8.8.8.8              # Reverse lookup (PTR)
nslookup google.com         # Simple forward lookup
```

## Who owns an IP or domain
```sh
whois 8.8.8.8               # IP ownership and registration info
whois google.com            # Domain registration info
```

## Where is an IP from
```sh
curl -s https://ipinfo.io/8.8.8.8           # JSON: city, region, org
curl -s https://ipinfo.io/8.8.8.8/country   # Country code only
```

## Who is on the network, are they reachable?
```sh
ping 192.168.1.1                      # Basic ping
ping -c 4 192.168.1.1                 # Send exactly 4 pings
arp -a                                # ARP table — known LAN IPs and MACs

# Ping broadcast to discover LAN hosts, then check ARP table
ping 192.168.1.255 &; sleep 5; kill %1; arp -a
```

## Scan a Port
```sh
nc -zw3 192.168.1.1 443 && echo "open" || echo "closed"   # Test a TCP port
nmap -p 22,80,443 192.168.1.1     # Scan specific ports (requires nmap)
```

## SSH: Remote Command Line
```sh
ssh user@server.address                    # Connect to remote host
ssh user@server.address -p 2222            # Specify a non-standard port
ssh user@server.address 'uptime'           # Run a command and exit
ssh -L 4433:192.168.1.1:443 user@jumphost  # SSH tunnel: proxy WAN → LAN resource

# Passwordless login (key-based auth)
ssh-keygen -t ed25519              # Generate an SSH key pair (leave passphrase blank for automation)
ssh-copy-id user@server.address    # Install your public key on the remote host
```

---

# User Functions

## Who am I?
```sh
whoami          # Current username
id              # Username, UID, and group memberships
```

## Who is signed in?
```sh
who             # Users currently logged in and their consoles
w               # Logged-in users with activity info
```

## Change password
```sh
passwd                  # Change the current user's password
passwd username         # Change another user's password (requires sudo)
sudo passwd username
```

## Switch user
```sh
su username             # Switch to another user
sudo -i                 # Open a root shell
sudo -u username bash   # Open a shell as another user
```

## List users and groups
```sh
dscl . list /Users                        # List all local users
dscl . list /Users | grep -v "^_"        # Exclude system accounts
dscl . read /Users/username               # Detailed info on a user
dscl . list /Groups                       # List all groups
dscacheutil -q group -a name admin        # Members of the admin group
id username                               # Groups a user belongs to
```

## Create and manage users
```sh
sudo dscl . -create /Users/newuser
sudo dscl . -create /Users/newuser UserShell /bin/zsh
sudo dscl . -create /Users/newuser RealName "Full Name"
sudo dscl . -create /Users/newuser UniqueID 502
sudo dscl . -create /Users/newuser PrimaryGroupID 20
sudo dscl . -passwd /Users/newuser password123

# Add user to the admin group (grants local admin)
sudo dscl . -append /Groups/admin GroupMembership newuser
```

---

# Mac-Specific Utilities

## Software Updates
```sh
softwareupdate -l                   # List available updates
softwareupdate -ia                  # Install all available updates
softwareupdate -i "Update Name-1.0" # Install a specific update
```

## Package Management (Homebrew)
```sh
brew install nmap            # Install a package
brew uninstall nmap          # Remove a package
brew update                  # Update Homebrew itself
brew upgrade                 # Upgrade all installed packages
brew list                    # List installed packages
brew search nmap             # Search for a package
```

## MDM and Enrollment
```sh
profiles show -type enrollment                          # Show MDM enrollment profile
sudo profiles -e -path /path/to/profile.mobileconfig   # Install a configuration profile
profiles list                                           # List all installed profiles
```

## Keychain and Certificates
```sh
security list-keychains                        # List keychains
security find-certificate -a -p /path/keys.keychain  # List certs in a keychain
security import cert.p12 -k login.keychain     # Import a certificate
```

## System Preferences (from Terminal)
```sh
# Enable/disable remote login (SSH)
sudo systemsetup -setremotelogin on
sudo systemsetup -setremotelogin off

# Set computer name
sudo scutil --set ComputerName  "NewName"
sudo scutil --set HostName      "NewName"
sudo scutil --set LocalHostName "NewName"

# Time zone
sudo systemsetup -settimezone "America/New_York"
sudo systemsetup -setusingnetworktime on
```

---

# Resources
- https://ss64.com/mac/ — macOS command reference
- https://www.explainshell.com/ — Parses complex command strings
- `man command` — Built-in manual pages for any command
- https://support.apple.com/guide/terminal/welcome/mac — Apple Terminal User Guide
