# The ‘user’ profile in some distributions like Ubuntu does not have direct access to the serial interfaces, commonly or formerly used for modem connections. 
# Run this, then log out and back in, or just reboot
gpasswd –add ${USER} dialout
