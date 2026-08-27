#!/usr/bin/env bash
# ==============================================================================
# MacBook Pro Sound Driver Installation Script (Cirrus Logic CS8409)
# Optimized for Fedora Linux
# ==============================================================================

set -e # Exit immediately if a command exits with a non-zero status

echo "=== [1/4] Installing Build Prerequisites & DKMS ==="
sudo dnf install -y gcc kernel-devel make patch git wget dkms kernel-headers

echo ""
echo "=== [2/4] Downloading Sound Driver Repository ==="
# Clean up any existing directory to avoid cloning conflicts
if [ -d "snd_hda_macbookpro" ]; then
    echo "Existing repository directory found. Removing it..."
    rm -rf snd_hda_macbookpro
fi

git clone https://github.com/davidjo/snd_hda_macbookpro.git
cd snd_hda_macbookpro/

echo ""
echo "=== [3/4] Running Driver Installation Script ==="
# Ignore the script's final directory check bug since Fedora correctly places modules in /extra/
sudo ./install.cirrus.driver.sh -i || true

echo ""
echo "=== [4/4] Installation Complete ==="
echo "Please reboot your system to load the driver by running: sudo reboot"
echo ""
echo "Post-Reboot Troubleshooting Note:"
echo "If sound does not work after rebooting, verify if Secure Boot blocked the module:"
echo "  sudo dmesg | grep cs8409"
echo "If you see a 'signature failure' or 'rejected' error, ensure Secure Boot is disabled."
