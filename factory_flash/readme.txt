1.copy the factory-flash.service to the /etc/systemd/system
2.copy the factory-flash.sh and rpi-clone to the /usr/local/sbin
3.give the factory-flash and rpi-clone excutable.(chmod +x factory-flash rpi-clone)
4.enable the factory-flash.service by using the command 'sudo systemctl enable factory-flash.service'