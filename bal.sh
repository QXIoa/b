#!/bin/bash
#
# shellcheck disable=SC1090,SC1091,SC2010,SC2016,SC2046,SC2086,SC2174
#
# Copyright (c) 2015-2024 OpenMediaVault Plugin Developers
# Copyright (c) 2017-2020 Armbian Developers
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.
#
# Ideas/code used from:
# https://github.com/armbian/config/blob/master/debian-software
# https://forum.openmediavault.org/index.php/Thread/25062-Install-OMV5-on-Debian-10-Buster/
#

logfile="omv_install.log"
scriptversion="2.3.10"


_log()
{
  msg=${1}
  echo "[$(date +'%Y-%m-%d %H:%M:%S%z')] [omvinstall] ${msg}" | tee -a ${logfile}
}

_log "script version :: ${scriptversion}"

if [[ $(id -u) -ne 0 ]]; then
  echo "This script must be executed as root or using sudo."
  exit 99
fi

systemd="$(ps --no-headers -o comm 1)"

declare -i armbian=0
declare -i cfg=0
declare -i ipv6=0
declare -i rpi=0
declare -i skipFlash=0
declare -i skipNet=0
declare -i skipReboot=0
declare -i useMirror=0
declare -i version

declare -l codename
declare -l omvCodename
declare -l omvInstall=""
declare -l omvextrasInstall=""

declare gov=""
declare minspd=""
declare maxspd=""

aptclean="/usr/sbin/omv-aptclean"
confCmd="omv-salt deploy run"
cpuFreqDef="/etc/default/cpufrequtils"
crda="/etc/default/crda"
defaultGovSearch="^CONFIG_CPU_FREQ_DEFAULT_GOV_"
forceIpv4="/etc/apt/apt.conf.d/99force-ipv4"
ioniceCron="/etc/cron.d/make_nas_processes_faster"
ioniceScript="/usr/sbin/omv-ionice"
keyserver="hkp://keyserver.ubuntu.com:80"
mirror="https://mirrors.tuna.tsinghua.edu.cn"
omvKey="/usr/share/keyrings/openmediavault-archive-keyring.gpg"
omvRepo="http://packages.openmediavault.org/public"
omvKeyUrl="${omvRepo}/archive.key"
omvSources="/etc/apt/sources.list.d/openmediavault.list"
resolvTmp="/root/resolv.conf"
rfkill="/usr/sbin/rfkill"
smbOptions=""
sshGrp="ssh"
url="https://github.com/OpenMediaVault-Plugin-Developers/packages/raw/master"
vsCodeList="/etc/apt/sources.list.d/vscode.list"
wpaConf="/etc/wpa_supplicant/wpa_supplicant.conf"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export LANG=C.UTF-8
export LANGUAGE=C
export LC_ALL=C.UTF-8

if [ -f /etc/armbian-release ]; then
  . /etc/armbian-release
  armbian=1
  _log "Armbian"
fi

while getopts "fhimnr" opt; do
  _log "option ${opt}"
  case "${opt}" in
    f)
      skipFlash=1
      ;;
    h)
      echo "Use the following flags:"
      echo "  -f"
      echo "    to skip the installation of the flashmemory plugin"
      echo "  -i"
      echo "    enable using IPv6 for apt"
      echo "  -m"
      echo "    to repo mirror from ${mirror}"
      echo "  -n"
      echo "    to skip the network setup"
      echo "  -r"
      echo "    to skip reboot"
      echo ""
      echo "Examples:"
      echo "  install"
      echo "  install -f"
      echo "  install -n"
      echo ""
      echo "Notes:"
      echo "  This script will always install:"
      echo "    - OMV 6.x (shaitan) on Debian 11 (Bullseye)"
      echo "    - OMV 7.x (sandworm) on Debian 12 (Bookworm)"
      echo ""
      exit 100
      ;;
    i)
      ipv6=1
      ;;
    m)
      useMirror=1
      omvRepo="${mirror}/OpenMediaVault/public"
      ;;
    n)
      skipNet=1
      ;;
    r)
      skipReboot=1
      ;;
    \?)
      _log "Invalid option: -${OPTARG}"
      ;;
  esac
done

_log "Starting ..."

# Fix permissions on / if wrong
_log "Current / permissions = $(stat -c %a /)"
chmod -v g-w,o-w / 2>&1 | tee -a ${logfile}
_log "New / permissions = $(stat -c %a /)"

# if ipv6 is not enabled, create apt config file to force ipv4
if [ ${ipv6} -ne 1 ]; then
  _log "Forcing IPv4 only for apt..."
  echo 'Acquire::ForceIPv4 "true";' > ${forceIpv4}
fi


if [ -f "/usr/libexec/config-rtl8367rb.sh" ]; then
  _log "Skipping network because swconfig controlled switch found."
  skipNet=1
fi

_log "Updating repos before installing..."
apt-get --allow-releaseinfo-change update 2>&1 | tee -a ${logfile}

_log "Installing lsb_release..."
apt-get --yes --no-install-recommends --reinstall install lsb-release 2>&1 | tee -a ${logfile}

arch="$(dpkg --print-architecture)"
_log "Arch :: ${arch}"

# exit if not supported architecture
case ${arch} in
  arm64|armhf|amd64|i386)
    _log "Supported architecture"
    ;;
  *)
    _log "Unsupported architecture :: ${arch}"
    exit 5
    ;;
esac

codename="$(lsb_release --codename --short)"
_log "Codename :: ${codename}"

case ${codename} in
  bullseye)
    keys="0E98404D386FA1D9 A48449044AAD5C5D"
    omvCodename="shaitan"
    version=6
    ;;
  bookworm)
    omvCodename="sandworm"
    version=7
    _log "Copying /etc/resolv.conf to ${resolvTmp} ..."
    cp -fv /etc/resolv.conf "${resolvTmp}"
    _log "$(cat /etc/resolv.conf)"
    sshGrp="_ssh"
    ;;
  *)
    _log "Unsupported version.  Only 11 (Bullseye) and 12 (Bookworm) are supported.  Exiting..."
    exit 1
  ;;
esac
_log "Debian :: ${codename}"
_log "${omvCodename} :: ${version}"

hostname="$(hostname --short)"
_log "Hostname :: ${hostname}"
domainname="$(hostname --domain)"
_log "Domain name :: ${domainname}"
tz="$(timedatectl show --property=Timezone --value)"
_log "timezone :: ${tz}"

regex='[a-zA-Z]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])'
if [[ ! ${hostname} =~ ${regex} ]]; then
    _log "Invalid hostname.  Exiting..."
    exit 6
fi

# Add Debian signing keys to raspbian to prevent apt-get update failures
# when OMV adds security and/or backports repos
if grep -rq raspberrypi.org /etc/apt/*; then
  rpivers="$(awk '$1 == "Revision" { print $3 }' /proc/cpuinfo)"
  _log "RPi revision code :: ${rpivers}"
  # https://elinux.org/RPi_HardwareHistory
  if [[ "${rpivers:0:1}" =~ [09] ]] && [[ ! "${rpivers:0:3}" =~ 902 ]]; then
    _log "This RPi1 is not supported (not true armhf).  Exiting..."
    exit 7
  fi
  rpi=1
  _log "Adding Debian signing keys..."
  for key in ${keys}; do
    apt-key adv --no-tty --keyserver ${keyserver} --recv-keys "${key}" 2>&1 | tee -a ${logfile}
  done
  _log "Installing monit from raspberrypi repo..."
  apt-get --yes --no-install-recommends install -t ${codename} monit 2>&1 | tee -a ${logfile}

  # remove vscode repo if found since there is no desktop environment
  # empty file will exist to keep raspberrypi-sys-mods package from adding it back
  truncate -s 0 "${vsCodeList}"
fi

# remove armbian netplan file if found
anp="/etc/netplan/armbian-default.yaml"
if [ -e "${anp}" ]; then
  _log "Removing Armbian netplan file..."
  rm -fv "${anp}"
fi

dpkg -P udisks2 2>&1 | tee -a ${logfile}

_log "Install prerequisites..."
apt-get --yes --no-install-recommends install gnupg wget 2>&1 | tee -a ${logfile}

if [ ${armbian} -eq 1 ]; then
  systemctl unmask systemd-networkd.service 2>&1 | tee -a ${logfile}
  # save off cpuFreq settings before installing the openmediavault
  if [ -f "${cpuFreqDef}" ]; then
    . ${cpuFreqDef}
    gov="${GOVERNOR}"
    minspd="${MIN_SPEED}"
    maxspd="${MAX_SPEED}"
  fi
fi

# make sure ssh is enabled
systemctl enable ssh.service

# install openmediavault if not installed already
omvInstall=$(dpkg -l | awk '$2 == "openmediavault" { print $1 }')
if [[ ! "${omvInstall}" == "ii" ]]; then
  _log "Installing openmediavault required packages..."
  apt-get --yes --no-install-recommends install postfix 2>&1 | tee -a ${logfile}
  if [ ${PIPESTATUS[0]} -gt 0 ]; then
    _log "failed installing postfix"
    sed -i '/^myhostname/d' /etc/postfix/main.cf
    apt-get --yes --fix-broken install 2>&1 | tee -a ${logfile}
    if [ ${PIPESTATUS[0]} -gt 0 ]; then
      _log "failed installing postfix and unable to fix"
      exit 2
    fi
  fi

  _log "Adding openmediavault repo and key..."
  echo "deb [signed-by=${omvKey}] ${omvRepo} ${omvCodename} main" | tee ${omvSources}
  wget --quiet --output-document=- "${omvKeyUrl}" | gpg --dearmor --yes --output "${omvKey}"

  _log "Updating repos..."
  apt-get update 2>&1 | tee -a ${logfile}
  if [ ${PIPESTATUS[0]} -gt 0 ]; then
    _log "failed to update apt repos."
    exit 2
  fi

  _log "Install openmediavault-keyring..."
  apt-get --yes install openmediavault-keyring 2>&1 | tee -a ${logfile}
  if [ ${PIPESTATUS[0]} -gt 0 ]; then
    _log "failed to install openmediavault-keyring package."
    exit 2
  fi

  monitInstall=$(dpkg -l | awk '$2 == "monit" { print $1 }')
  if [[ ! "${monitInstall}" == "ii" ]]; then
    apt-get --yes --no-install-recommends install monit 2>&1 | tee -a ${logfile}
    if [ ${PIPESTATUS[0]} -gt 0 ]; then
      _log "failed installing monit"
      exit 2
    fi
  fi

  _log "Installing openmediavault..."
  aptFlags="--yes --auto-remove --show-upgraded --allow-downgrades --allow-change-held-packages --no-install-recommends"
  apt-get ${aptFlags} install openmediavault 2>&1 | tee -a ${logfile}
  if [ ${PIPESTATUS[0]} -gt 0 ]; then
    _log "failed to install openmediavault package."
    exit 2
  fi

  omv-confdbadm populate 2>&1 | tee -a ${logfile}
  omv-salt deploy run hosts 2>&1 | tee -a ${logfile}
fi
_log "Testing DNS..."
if ! ping -4 -q -c2 omv-extras.org 2>/dev/null; then
  _log "DNS failing to resolve.  Fixing ..."
  if [ -f "${resolvTmp}" ]; then
    _log "Reverting /etc/resolv.conf to saved copy ..."
    rm -fv /etc/resolv.conf
    cp -v "${resolvTmp}" /etc/resolv.conf
  fi
fi

# check if openmediavault is install properly
omvInstall=$(dpkg -l | awk '$2 == "openmediavault" { print $1 }')
if [[ ! "${omvInstall}" == "ii" ]]; then
  _log "openmediavault package failed to install or is in a bad state."
  exit 3
fi

. /etc/default/openmediavault
. /usr/share/openmediavault/scripts/helper-functions

# remove backports from sources.list to avoid duplicate sources warning
sed -i "/\(stretch\|buster\|bullseye\)-backports/d" /etc/apt/sources.list

if [ ${rpi} -eq 1 ]; then
  if [ ! "${arch}" = "arm64" ]; then
    omv_set_default "OMV_APT_USE_OS_SECURITY" false true
  fi
  omv_set_default "OMV_APT_USE_KERNEL_BACKPORTS" false true
fi

# change repos if useMirror is specified
if [ ${useMirror} -eq 1 ]; then
  _log "Changing repos to mirror from ${mirror} ..."
  omv_set_default OMV_APT_REPOSITORY_URL "${mirror}/OpenMediaVault/public" true
  omv_set_default OMV_APT_ALT_REPOSITORY_URL "${mirror}/OpenMediaVault/packages" true
  omv_set_default OMV_APT_KERNEL_BACKPORTS_REPOSITORY_URL "${mirror}/debian" true
  omv_set_default OMV_APT_SECURITY_REPOSITORY_URL "${mirror}/debian-security" true
  omv_set_default OMV_EXTRAS_APT_REPOSITORY_URL "${mirror}/OpenMediaVault/openmediavault-plugin-developers" true
  omv_set_default OMV_DOCKER_APT_REPOSITORY_URL "${mirror}/docker-ce/linux/debian" true
  omv_set_default OMV_PROXMOX_APT_REPOSITORY_URL "${mirror}/proxmox/debian" true

  # update pillar default list - /srv/pillar/omv/default.sls
  omv-salt stage run prepare 2>&1 | tee -a ${logfile}

  # update config files
  ${confCmd} apt 2>&1 | tee -a ${logfile}
fi

# install omv-extras
_log "Downloading omv-extras.org plugin for openmediavault ${version}.x ..."
file="openmediavault-omvextrasorg_latest_all${version}.deb"

if [ -f "${file}" ]; then
  rm ${file}
fi
wget ${url}/${file}
if [ -f "${file}" ]; then
  if ! dpkg --install ${file}; then
    _log "Installing other dependencies ..."
    apt-get --yes --fix-broken install 2>&1 | tee -a ${logfile}
    omvextrasInstall=$(dpkg -l | awk '$2 == "openmediavault-omvextrasorg" { print $1 }')
    if [[ ! "${omvextrasInstall}" == "ii" ]]; then
      _log "omv-extras failed to install correctly.  Trying to fix apt ..."
      apt-get --yes --fix-broken install 2>&1 | tee -a ${logfile}
      if [ ${PIPESTATUS[0]} -gt 0 ]; then
        _log "Fix failed and openmediavault-omvextrasorg is in a bad state."
        exit 3
      fi
    fi
    omvextrasInstall=$(dpkg -l | awk '$2 == "openmediavault-omvextrasorg" { print $1 }')
    if [[ ! "${omvextrasInstall}" == "ii" ]]; then
      _log "openmediavault-omvextrasorg package failed to install or is in a bad state."
      exit 3
    fi
  fi

  _log "Updating repos ..."
  ${aptclean} repos 2>&1 | tee -a ${logfile}
else
  _log "There was a problem downloading the package."
fi

# disable armbian log services if found
for service in log2ram armbian-ramlog armbian-zram-config; do
  if systemctl list-units --full -all | grep ${service}; then
    systemctl stop ${service} 2>&1 | tee -a ${logfile}
    systemctl disable ${service} 2>&1 | tee -a ${logfile}
  fi
done
rm -f /etc/cron.daily/armbian-ram-logging
if [ -f "/etc/default/armbian-ramlog" ]; then
  sed -i "s/ENABLED=.*/ENABLED=false/g" /etc/default/armbian-ramlog
fi
if [ -f "/etc/default/armbian-zram-config" ]; then
  sed -i "s/ENABLED=.*/ENABLED=false/g" /etc/default/armbian-zram-config
fi
if [ -f "/etc/systemd/system/logrotate.service" ]; then
  rm -f /etc/systemd/system/logrotate.service
  systemctl daemon-reload
fi

# install flashmemory plugin unless disabled
if [ ${skipFlash} -eq 1 ]; then
  _log "Skipping installation of the flashmemory plugin."
else
  _log "Install folder2ram..."
  apt-get --yes --fix-missing --no-install-recommends install folder2ram 2>&1 | tee -a ${logfile}
  if [ ${PIPESTATUS[0]} -eq 0 ]; then
    _log "Installed folder2ram."
  else
    _log "Failed to install folder2ram."
  fi
  _log "Install flashmemory plugin..."
  apt-get --yes install openmediavault-flashmemory 2>&1 | tee -a ${logfile}
  if [ ${PIPESTATUS[0]} -eq 0 ]; then
    _log "Installed flashmemory plugin."
  else
    _log "Failed to install flashmemory plugin."
    ${confCmd} flashmemory 2>&1 | tee -a ${logfile}
    apt-get --yes --fix-broken install 2>&1 | tee -a ${logfile}
  fi
fi

# change default OMV settings
if [ -n "${smbOptions}" ]; then
  omv_config_update "/config/services/smb/extraoptions" "$(echo -e "${smbOptions}")"
fi
omv_config_update "/config/services/ssh/enable" "1"
omv_config_update "/config/services/ssh/permitrootlogin" "1"
omv_config_update "/config/system/time/ntp/enable" "1"
omv_config_update "/config/system/time/timezone" "${tz}"
omv_config_update "/config/system/network/dns/hostname" "${hostname}"
if [ -n "${domainname}" ]; then
  omv_config_update "/config/system/network/dns/domainname" "${domainname}"
fi

# disable monitoring and apply changes
_log "Disabling data collection ..."
/usr/sbin/omv-rpc -u admin "perfstats" "set" '{"enable":false}' 2>&1 | tee -a ${logfile}
/usr/sbin/omv-rpc -u admin "config" "applyChanges" '{ "modules": ["monit","rrdcached","collectd"],"force": true }' 2>&1 | tee -a ${logfile}

# set min/max frequency and watchdog for RPi boards
rpi_model="/proc/device-tree/model"
if [ -f "${rpi_model}" ] && [[ $(awk '{ print $1 }' ${rpi_model}) = "Raspberry" ]]; then
  if [ ${version} -lt 6 ]; then
    omv_set_default "OMV_WATCHDOG_DEFAULT_MODULE" "bcm2835_wdt"
    omv_set_default "OMV_WATCHDOG_CONF_WATCHDOG_TIMEOUT" "14"
  fi
  omv_set_default "OMV_WATCHDOG_SYSTEMD_RUNTIMEWATCHDOGSEC" "14s" true

  MIN_SPEED="$(</sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq)"
  MAX_SPEED="$(</sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)"
  # Determine if RPi4 (for future use)
  if [[ $(awk '$1 == "Revision" { print $3 }' /proc/cpuinfo) =~ [a-c]03111 ]]; then
    BOARD="rpi4"
  fi
  cat << EOF > ${cpuFreqDef}
GOVERNOR="schedutil"
MIN_SPEED="${MIN_SPEED}"
MAX_SPEED="${MAX_SPEED}"
EOF
fi

# get default governor for kernel
modprobe --quiet configs
if [ -f "/proc/config.gz" ]; then
  defaultGov="$(zgrep "${defaultGovSearch}" /proc/config.gz | sed -e "s/${defaultGovSearch}\(.*\)=y/\1/")"
elif [ -f "/boot/config-$(uname -r)" ]; then
  defaultGov="$(grep "${defaultGovSearch}" /boot/config-$(uname -r) | sed -e "s/${defaultGovSearch}\(.*\)=y/\1/")"
fi

# governor and speed variables
if [ ${armbian} -eq 1 ]; then
  if [ -n "${defaultGov}" ]; then
    GOVERNOR="${defaultGov,,}"
  elif [ -n "${gov}" ]; then
    GOVERNOR="${gov}"
  fi
  if [ -n "${minspd}" ]; then
    MIN_SPEED="${minspd}"
  fi
  if [ -n "${maxspd}" ]; then
    MAX_SPEED="${maxspd}"
  fi
elif [ -f "${cpuFreqDef}" ]; then
  . ${cpuFreqDef}
else
  if [ -z "${DEFAULT_GOV}" ]; then
    defaultGov="ondemand"
  fi
  GOVERNOR=${defaultGov,,}
  MIN_SPEED="0"
  MAX_SPEED="0"
fi

# set defaults in /etc/default/openmediavault
omv_set_default "OMV_CPUFREQUTILS_GOVERNOR" "${GOVERNOR}"
omv_set_default "OMV_CPUFREQUTILS_MINSPEED" "${MIN_SPEED}"
omv_set_default "OMV_CPUFREQUTILS_MAXSPEED" "${MAX_SPEED}"

# update pillar default list - /srv/pillar/omv/default.sls
omv-salt stage run prepare 2>&1 | tee -a ${logfile}

# update config files
${confCmd} nginx phpfpm samba flashmemory ssh chrony timezone monit rrdcached collectd cpufrequtils apt watchdog 2>&1 | tee -a ${logfile}

# create php directories if they don't exist
modDir="/var/lib/php/modules"
if [ ! -d "${modDir}" ]; then
  mkdir --parents --mode=0755 ${modDir}
fi
sessDir="/var/lib/php/sessions"
if [ ! -d "${sessDir}" ]; then
  mkdir --parents --mode=1733 ${sessDir}
fi

if [ -f "${forceIpv4}" ]; then
  rm ${forceIpv4}
fi

if [ -f "/etc/init.d/proftpd" ]; then
  systemctl disable proftpd.service
  systemctl stop proftpd.service
fi

# add admin user to openmediavault-admin group if it exists
if getent passwd admin > /dev/null; then
  usermod -a -G openmediavault-admin admin 2>&1 | tee -a ${logfile}
fi

if [[ "${arch}" == "amd64" ]] || [[ "${arch}" == "i386" ]]; then
  # skip ionice on x86 boards
  _log "Done."
  exit 0
fi

if [ ! "${GOVERNOR,,}" = "schedutil" ]; then
  _log "Add a cron job to make NAS processes more snappy and silence rsyslog"
  cat << EOF > /etc/rsyslog.d/omv-armbian.conf
:msg, contains, "omv-ionice" ~
:msg, contains, "action " ~
:msg, contains, "netsnmp_assert" ~
:msg, contains, "Failed to initiate sched scan" ~
EOF
  systemctl restart rsyslog 2>&1 | tee -a ${logfile}

  # add taskset to ionice cronjob for biglittle boards
  case ${BOARD} in
    odroidxu4|bananapim3|nanopifire3|nanopct3plus|nanopim3|nanopi-r6s)
      taskset='; taskset -c -p 4-7 ${srv}'
      ;;
    *rk3399*|*edge*|nanopct4|nanopim4|nanopineo4|renegade-elite|rockpi-4*|rockpro64|helios64)
      taskset='; taskset -c -p 4-5 ${srv}'
      ;;
    odroidn2)
      taskset='; taskset -c -p 2-5 ${srv}'
      ;;
  esac

  # create ionice script
  cat << EOF > ${ioniceScript}
#!/bin/sh

for srv in \$(pgrep "ftpd|nfsiod|smbd"); do
  ionice -c1 -p \${srv} ${taskset};
done
EOF
  chmod 755 ${ioniceScript}

  # create ionice cronjob
  cat << EOF > ${ioniceCron}
* * * * * root ${ioniceScript} >/dev/null 2>&1
EOF
  chmod 600 ${ioniceCron}
fi

# add pi user to ssh group if it exists
if getent passwd pi > /dev/null; then
  _log "Adding pi user to ssh group ..."
  usermod -a -G ${sshGrp} pi
fi

# add user running the script to ssh group if not pi or root
if [ -n "${SUDO_USER}" ] && [ ! "${SUDO_USER}" = "root" ] && [ ! "${SUDO_USER}" = "pi" ]; then
  if getent passwd ${SUDO_USER} > /dev/null; then
    _log "Adding ${SUDO_USER} to the ${sshGrp} group ..."
    usermod -a -G ${sshGrp} ${SUDO_USER}
  fi
fi

# remove networkmanager and dhcpcd5 then configure networkd
if [ ${skipNet} -ne 1 ]; then

  if [ "${BOARD}" = "helios64" ]; then
    echo -e '#!/bin/sh\n/usr/sbin/ethtool --offload eth1 rx off tx off' > /usr/lib/networkd-dispatcher/routable.d/10-disable-offloading
  fi

  defLink="/etc/systemd/network/99-default.link"
  rm -fv "${defLink}"
  if [ ${rpi} -eq 1 ] && [ ${version} -eq 7 ]; then
    _log "Force eth0 name on RPi ..."
    mac="$(ip -j a show dev eth0 | jq -r .[].address | head -n1)"
    if [ -z "${mac}" ]; then
      mac="$(ip -j a show dev end0 | jq -r .[].address | head -n1)"
    fi
    _log "mac address - ${mac}"
    if [ -n "${mac}" ]; then
      echo -e "[Match]\nMACAddress=${mac}\n[Link]\nName=eth0" > /etc/systemd/network/10-persistent-eth0.link
    fi
  fi

  _log "Removing network-manager and dhcpcd5 ..."
  apt-get -y --autoremove purge network-manager dhcpcd5 2>&1 | tee -a ${logfile}

  _log "Enable and start systemd-resolved ..."
  systemctl enable systemd-resolved 2>&1 | tee -a ${logfile}
  systemctl start systemd-resolved 2>&1 | tee -a ${logfile}
  rm /etc/resolv.conf
  ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

  if [ -f "${rfkill}" ]; then
    _log "Unblocking wifi with rfkill ..."
    ${rfkill} unblock all
  fi

  for nic in $(ls /sys/class/net | grep -vE "br-|docker|dummy|ip6|lo|sit|tun|veth|virbr|wg"); do
    if grep -q "<devicename>${nic}</devicename>" ${OMV_CONFIG_FILE}; then
      _log "${nic} already found in database.  Skipping..."
      continue
    fi
    if udevadm info /sys/class/net/${nic} | grep -q wlan; then
      if [ -f "${wpaConf}" ]; then
        country=$(awk -F'=' '/country=/{gsub(/["\r]/,""); print $NF}' ${wpaConf})
        wifiName=$(awk -F'=' '/ssid="/{st=index($0,"="); ssid=substr($0,st+1); gsub(/["\r]/,"",ssid); print ssid; exit}' ${wpaConf})
        wifiPass=$(awk -F'=' '/psk="/{st=index($0,"="); pass=substr($0,st+1); gsub(/["\r]/,"",pass); print pass; exit}' ${wpaConf})

        if [ -n "${country}" ] && [ -n "${wifiName}" ] && [ -n "${wifiPass}" ]; then
          if [ -f "${crda}" ]; then
            awk -i inplace -F'=' -v country="$country" '/REGDOMAIN=/{$0=$1"="country} {print $0}' ${crda}
          fi
          _log "Adding ${nic} to openmedivault database ..."
          jq --null-input --compact-output \
            "{uuid: \"${OMV_CONFIGOBJECT_NEW_UUID}\", devicename: \"${nic}\", type: \"wifi\", method: \"dhcp\", method6: \"dhcp\", wpassid: \"${wifiName}\", wpapsk: \"${wifiPass}\"}" | \
            omv-confdbadm update "conf.system.network.interface" -
          if grep -q "<devicename>${nic}</devicename>" ${OMV_CONFIG_FILE}; then
            cfg=1
          fi
        fi
      fi
    else
      _log "Adding ${nic} to openmedivault database ..."
      if [ -n "$(ip -j -o -4 addr show ${nic} | jq --raw-output  '.[] | select(.addr_info[0].dev) | .addr_info[0].local')" ] && \
      [ "$(ip -j -o -4 addr show ${nic} | jq --raw-output '.[] | select(.addr_info[0].dev) | .addr_info[0].dynamic')" == "null" ]; then
        ipv4Addr=$(ip -j -o -4 addr show ${nic} | jq --raw-output '.[] | select(.addr_info[0].dev) | .addr_info[0].local')
        ipv4CIDR=$(ip -j -o -4 addr show ${nic} | jq --raw-output '.[] | select(.addr_info[0].dev) | .addr_info[0].prefixlen')
        bitmaskValue=$(( 0xffffffff ^ ((1 << (32 - ipv4CIDR)) - 1) ))
        ipv4Netmask=$(( (bitmaskValue >> 24) & 0xff )).$(( (bitmaskValue >> 16) & 0xff )).$(( (bitmaskValue >> 8) & 0xff )).$(( bitmaskValue & 0xff ))
        ipv4GW=$(ip -j -o -4 route show | jq --raw-output '.[] | select(.dst=="default") | .gateway')
        jq --null-input --compact-output \
        "{uuid: \"${OMV_CONFIGOBJECT_NEW_UUID}\", devicename: \"${nic}\", method: \"static\", address: \"${ipv4Addr}\", netmask: \"${ipv4Netmask}\", gateway: \"${ipv4GW}\", dnsnameservers: \"8.8.8.8 ${ipv4GW}\"}" | \
        omv-confdbadm update "conf.system.network.interface" -
      else
        jq --null-input --compact-output \
        "{uuid: \"${OMV_CONFIGOBJECT_NEW_UUID}\", devicename: \"${nic}\", method: \"dhcp\", method6: \"dhcp\"}" | \
        omv-confdbadm update "conf.system.network.interface" -
      fi

      if grep -q "<devicename>${nic}</devicename>" ${OMV_CONFIG_FILE}; then
        cfg=1
      fi
    fi
  done

  if [ ${cfg} -eq 1 ]; then
    _log "IP address may change and you could lose connection if running this script via ssh."

    # create config files
    ${confCmd} systemd-networkd 2>&1 | tee -a ${logfile}
    if [ ${PIPESTATUS[0]} -gt 0 ]; then
      _log "Error applying network changes.  Skipping reboot!"
      skipReboot=1
    fi

    if [ ${skipReboot} -ne 1 ]; then
      _log "Network setup.  Rebooting..."
      reboot
    fi
  else
    _log "It is recommended to reboot and then setup the network adapter in the openmediavault web interface."
  fi

fi

_log "done."

exit 0
