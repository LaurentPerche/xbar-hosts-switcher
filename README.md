# xbar-hosts-switcher

A macOS menu bar plugin for xbar that switches `/etc/hosts`
between multiple host profile files, with a built in SAFE profile that
syncs from StevenBlack’s hosts list. Uses `sudo` so Touch ID can be used.

<img width="371" height="356" alt="Screenshot_2026-02-14_at_2 40 05_PM-removebg-preview" src="https://github.com/user-attachments/assets/bba1dd64-8673-4784-93b7-0a69b09d7e5b" />


## Features

• Switch `/etc/hosts` between any profile files in a folder  
• SAFE profile auto sync from StevenBlack  
• “Refresh SAFE now” updates SAFE and re applies it if SAFE is active  
• Uses `sudo`, supports Touch ID  
• Opens the active profile file in your default text editor  

## Requirements

• macOS  
• xbar installed  
• curl  
• optional but recommended: Touch ID enabled for sudo

## Install

1. Copy the plugin into your xbar plugins folder:

`~/Library/Application Support/xbar/plugins/`

2. Make it executable:

`chmod +x hosts-switcher-stevenblack.5m.sh`

3. Refresh xbar.

## Touch ID for sudo (recommended)

1. Back up the sudo PAM file:

`sudo cp /etc/pam.d/sudo /etc/pam.d/sudo.bak`

2. Edit it:

`sudo nano /etc/pam.d/sudo`

3. Add this line near the top:

`auth       sufficient     pam_tid.so`

Test:

`sudo -v`

## Profiles

Profiles live here:

`~/.config/xbar-hosts-switcher/profiles/`

Every file in that folder appears in the menu and can be applied.

The plugin creates:
• `SAFE.hosts`  
• `UNSAFE.hosts`

## SAFE upstream

SAFE is fetched from StevenBlack:

https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts

## License

MIT
