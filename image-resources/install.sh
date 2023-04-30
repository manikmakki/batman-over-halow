#!/usr/bin/env bash

APT_REPOS_URL="https://downloads.alfa.com.tw/raspbian"

show_motd() {
	cat <<EOD

    ____   __   ____  ____     _____     _                 _
   /  _ \ |  | |  __|/  _ \   |   | |___| |_ _ _ _ ___ ___| |_
  /  /_\ \|  |_|  __/  /_\ \  | | | | -_|  _| | | | . |  _| '_|
 /__/ \___|____|_| /__/ \___\ |_|___|___|_| |_____|___|_| |_,_|

EOD
}

#
# This is a hijack hook function
#
# The function will substitute the interactive part of raspbi-config and overload the whiptail funtion,
#  so that we can reuse the raspi-config original setup procedures.
#
invoke_raspi_config() {
	local ORIG=$(which raspi-config)
	local FORK=$(mktemp)

	cat $ORIG | grep -B $(wc -l $ORIG | cut -d' ' -f1) -e "^# Interactive use loop" >$FORK
	cat >>$FORK <<EOD

	$(declare -f whiptail)

	$@
EOD

	chmod +x $FORK && (sudo $FORK)
	rm $FORK
}

setup_apt() {
	sudo apt update
}

setup_depends() {
	PKGS=""
	PKGS="$PKGS dkms iptables"
	PKGS="$PKGS hostapd dnsmasq"
	PKGS="$PKGS vim iperf iperf3"
	PKGS="$PKGS git"
	PKGS="$PKGS picocom"                              # Standalone UART console

	sudo apt install -y $PKGS
}

setup_kernel() {
	[ -e "/lib/modules/$(uname -r)/build/.config" ] &&
		(dpkg -s raspberrypi-kernel-headers >/dev/null 2>&1) && return

	sudo apt install -y raspberrypi-kernel raspberrypi-kernel-headers
	touch /tmp/.need_reboot
}

setup_ssh() {
	whiptail() {
		if (printf -- "$*" | grep -e "--yesno" >/dev/null 2>&1); then
			if (printf -- "$*" | grep -e "Would you like the SSH server to be enabled?" >/dev/null 2>&1); then
				return 0 # Anwser yes
			fi

			printf -- "[Err] Unknown: >>>$*\n" && exit
		fi
		printf -- ">>> $* \n"
	}

	invoke_raspi_config "do_ssh"
	unset -f whiptail
}


setup_spi() {
	whiptail() {
		if (printf -- "$*" | grep -e "--yesno" >/dev/null 2>&1); then
			if (printf -- "$*" | grep -e "Would you like the SPI interface to be enabled?" >/dev/null 2>&1); then
				return 0 # Anwser yes
			fi

			printf -- "[Err] Unknown: >>>$*\n" && exit
		fi
		printf -- ">>> $* \n"
	}

	invoke_raspi_config "do_spi"
	unset -f whiptail
}

setup_serial() {
	whiptail() {
		if (printf -- "$*" | grep -e "--yesno" >/dev/null 2>&1); then
			if (printf -- "$*" | grep -e "Would you like a login shell to be accessible over serial?" >/dev/null 2>&1); then
				return 1 # Anwser no
			fi
			if (printf -- "$*" | grep -e "Would you like the serial port hardware to be enabled?" >/dev/null 2>&1); then
				return 0 # Anwser yes
			fi

			printf -- "[Err] Unknown: >>>$*\n" && exit
		fi
		printf -- ">>> $* \n"
	}

	invoke_raspi_config "do_serial"
	unset -f whiptail
}

setup_nrc7292_pkgs() {
	[ -e /etc/apt/sources.list.d/alfa.list ] || {
		curl -sL "$APT_REPOS_URL/raspbian.public.key" | sudo apt-key add -
		echo "deb $APT_REPOS_URL/ bullseye main contrib non-free firmware rpi" | sudo tee /etc/apt/sources.list.d/alfa.list
	}

	(dpkg -s nrc7292-dkms >/dev/null 2>&1) &&
		(dpkg -s nrc7292-firmware >/dev/null 2>&1) &&
		(dpkg -s nrc7292-nrc-pkg >/dev/null 2>&1) && return

	sudo apt update
	sudo apt install -y nrc7292-dkms nrc7292-firmware nrc7292-nrc-pkg || {
		echo "[Err] Install nrc7292 packages failed."
		exit 1
	}
}

setup_nrc7292_sdk() {
	SDK_DIR="$HOME/nrc7292_sdk"
	SDK_URL="https://github.com/newracom/nrc7292_sdk.git"
	[ -e "$SDK_DIR" ] || {
		git clone "$SDK_URL" "$SDK_DIR"
		(
			cd $SDK_DIR
			git apply <(curl -sL $APT_REPOS_URL/nrc7292_sdk.patch.txt)
		)
	}
}

setup_dtoverlays() {
	local target_file="/boot/config.txt"

	(cat $target_file | grep -e "#### Custom newracom block" >/dev/null 2>&1) || touch /tmp/.need_reboot

	local block_beg=$(cat $target_file | grep -n "#### Custom newracom block beg ####" | cut -d: -f1)
	block_beg=${block_beg:-0}
	local block_end=$(cat $target_file | grep -n "#### Custom newracom block end ####" | cut -d: -f1)
	block_end=${block_end:-0}

	if [ $block_beg -gt 0 -a $block_end -gt 0 -a $block_end -gt $block_beg ]; then
		# Remove duplicated block to keep idempotent
		sudo sed -i $target_file -e "${block_beg},${block_end}d"
	fi

	cat | sudo tee -a $target_file <<EOD
#### Custom newracom block beg ####
[newracom]
dtoverlay=disable-bt
dtoverlay=disable-wifi
dtoverlay=disable-spidev
dtoverlay=miniuart-bt
#### Custom newracom block end ####
EOD
}

AUTOSTART_FILE="$HOME/.config/autostart/nrc7292_setup.desktop"

add_autostart() {
	del_autostart

	install -D /dev/null $AUTOSTART_FILE
	cat >$AUTOSTART_FILE <<EOD
[Desktop Entry]
Type=Application
Name=nrc7292_setup
Exec=/usr/bin/lxterminal -e 'bash -c "(for nn in \\\`seq 1 60\\\`; do ping -W 1 -n -c 1 alfa.com.tw >/dev/null 2>&1 && break; echo -n . ; sleep 1; done); curl -sL $APT_REPOS_URL/nrc7292_setup.sh.txt | bash -"'
EOD
}

del_autostart() {
	[ -e "$AUTOSTART_FILE" ] && rm "$AUTOSTART_FILE"
}

reboot_if_needed() {
	[ -e /tmp/.need_reboot ] && {
		whiptail --msgbox "The system need reboot. Please press any key to reboot..." 10 40
		add_autostart
		sync && sync && sync && sleep 5
		reboot
	}
}

end_message() {
	cat <<EOD
[Done] The setup program finished.
EOD
	read -p "Press any key to continue..." <"$(tty 0>&2)"
}

main() {
	export LC_ALL="C.UTF-8"
	show_motd
	del_autostart
	setup_apt
	setup_depends
	setup_kernel
	reboot_if_needed
	setup_ssh
	setup_spi
	setup_serial
	reboot_if_needed
	setup_nrc7292_pkgs
	setup_dtoverlays
	reboot_if_needed
	setup_nrc7292_sdk
	reboot_if_needed
	end_message
}

main $@