#!/bin/bash

_dir=`dirname $0`

log () {
    echo "$1"
}

get_system () {
    local data=""
    local raw_release=""
    local lsb_release_bin;
    lsb_release_bin=$(which lsb_release 2> /dev/null)

    if [ "$?" = "0" ]; then
        raw_release=$("${lsb_release_bin}" -d)
    elif [ -f "/etc/os-release" ]; then
        name=$(cat /etc/os-release | grep '^NAME=' | cut -d'"' -f2)
        version=$(cat /etc/os-release | grep '^VERSION=' | cut -d'"' -f2)
        raw_release="$name $version"
    else
        raw_release=$(cat /etc/*-release)
    fi

    data=$(echo "${raw_release}" | gawk '
        BEGIN {
            distro_name = ""
            distro_version = ""
        }

        /^ *$/ {
            next
        }

        /^ *(.+) +([0-9]+(\.[0-9]+)?)(.+)?$/ {
            distro_name = gensub(/^ *(.+) +([0-9]+(\.[0-9]+)?)(.+)?$/, "\\1", "g")

            if (distro_name ~ /^Description:[ \t]+/) {
                sub(/^Description:[ \t]+/, "", distro_name)
            }

            if (distro_name ~ /^Red Hat Enterprise Linux/) {
                distro_name = "rhel"
            } else if (distro_name ~ /^CentOS release$/ || distro_name ~ /^CentOS Linux$/ || distro_name ~ /^CentOS Linux release$/) {
                distro_name = "centos"
            } else if (distro_name ~ /^Fedora$/) {
                distro_name = "fedora"
            } else if (distro_name ~ /^SUSE Linux Enterprise/ || distro_name ~ /^SLES*/) {
                distro_name = "suse"
            } else if (distro_name ~ /^Debian GNU\/Linux$/) {
                distro_name = "debian"
            } else if (distro_name ~ /^Ubuntu$/) {
                distro_name = "ubuntu"
            } else if (distro_name ~ /^Oracle Linux Server release$/) {
                distro_name = "oracle"
            } else if (distro_name ~ /^Amazon Linux.*$/) {
                distro_name = "amazon"
            } else {
                distro_name = ""
            }

            distro_version = gensub(/^ *(.+) +([0-9]+(\.[0-9]+)?)(.+)?$/, "\\2", "g")
            next
        }

        END {
            print distro_name";"distro_version
        }
    ')

    if [ "${data}" != "" ]; then
        echo $data
    fi
}

disable_selinux () {
    sed -i 's/SELINUX\=enforcing/SELINUX\=disabled/g' /etc/selinux/config
}

disable_wayland () {
    sed -i 's/#WaylandEnable/WaylandEnable/g' /etc/gdm/custom.conf
}

check_nvidia_card () {
    # TODO: maybe also grep for quadro/grid/tesla and warn if it is a consumer card?
    echo $(lspci 2>/dev/null | grep -i nvidia > /dev/null && echo "Yes" || echo "No")
}

check_nouveau () {
    if lsmod | grep -i nouveau > /dev/null &&
       ! [ -f /etc/modprobe.d/nvidia-installer-disable-nouveau.conf ]; then
        echo "Yes"
    else
        echo "No"
    fi
}

disable_nouveau () {
    # from http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/install-nvidia-driver.html
    grep nouveau /etc/modprobe.d/blacklist.conf > /dev/null
    if [ "$?" = "1" ]; then
        echo "blacklist vga16fb" >> /etc/modprobe.d/blacklist.conf
        echo "blacklist nouveau" >> /etc/modprobe.d/blacklist.conf
        echo "blacklist rivafb" >> /etc/modprobe.d/blacklist.conf
        echo "blacklist nvidiafb" >> /etc/modprobe.d/blacklist.conf
        echo "blacklist rivatv" >> /etc/modprobe.d/blacklist.conf
    fi

    if [ -f /etc/default/grub ]; then
        if grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub >/dev/null; then
            sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT=".*\)"/\1 modprobe.blacklist=nouveau"/' /etc/default/grub
        else
            echo 'GRUB_CMDLINE_LINUX_DEFAULT="modprobe.blacklist=nouveau"' >> /etc/default/grub
        fi
        grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        sed -i 's/\(kernel .*\)/\1 rdblacklist=nouveau nouveau.modeset=0/' /boot/grub/grub.conf
    fi
}

install_nvidia_driver_dependencies (){
    yum -y install kernel-devel kernel-headers gcc make dkms
}

download_nvidia_driver_for_g3 () {
    local arch_path="Linux-x86_64"
    local driver_name=""
    local prefix="latest/"

    log "Retrieving NVIDIA driver for G3 instances from S3 (${prefix})"

    driver_name=`aws s3 ls s3://ec2-linux-nvidia-drivers/${prefix} | awk '{print $4}' | grep NVIDIA-${arch_path}-.*-grid.*.run`

    log "NVIDIA driver to be downloaded: ${driver_name}"
    if [ -n ${driver_name} ]; then
        aws s3 cp "s3://ec2-linux-nvidia-drivers/${prefix}${driver_name}" /opt/dcv-install/

        if [ "$?" = "0" ]; then
            log "NVIDIA driver downloaded"
            ln -s "/opt/dcv-install/${driver_name}" "/opt/dcv-install/NVIDIA-${arch_path}.run"
            install_nvidia_driver_dependencies
        else
            log "Failed to download nvidia driver from S3"
        fi
    else
        log "Unable to find nvidia driver on S3"
    fi
}

download_nvidia_driver_for_g4 () {
    local driver_name=""
    local arch_path="Linux-x86_64"
    local nvidia_bucket="ec2-linux-nvidia-drivers"
    local prefix="latest/"

    driver_name=`aws s3 ls s3://$nvidia_bucket/${prefix} | awk '{print $4}' | grep NVIDIA-${arch_path}-.*-grid-aws.run`

    log "Retrieving NVIDIA grid driver for G4 instances from S3 (${prefix})"

    log "NVIDIA driver to be downloaded: ${driver_name}"
    if [ -n ${driver_name} ]; then
        aws s3 cp "s3://$nvidia_bucket/${prefix}${driver_name}" /opt/dcv-install/
        if [ "$?" = "0" ]; then
            log "NVIDIA driver downloaded"
            ln -s "/opt/dcv-install/${driver_name}" "/opt/dcv-install/NVIDIA-${arch_path}.run"
            install_nvidia_driver_dependencies
        else
            log "Failed to download nvidia driver from S3"
        fi
    else
        log "Unable to find nvidia driver on S3"
    fi
}

if [ `id -u` -ne 0 ]; then
    log "You must be root to deploy dcv."
    exit 1
fi

if [ ! -f "${_dir}/conf.sh" ]; then
    log "Conf file does not exist. Exiting..."
    exit 1
fi

system_version=$(get_system)
system=${system_version%%;*}
system_version=${system_version#*;}
system_major_version=${system_version%%.*}
instance=$(curl http://169.254.169.254/latest/meta-data/instance-id)

if [ "${system}" != "centos" -a $system_major_version != 7 ]; then
    log "Only CentOS7 is currently supported"
    exit 1
fi

. "${_dir}/conf.sh"

aws s3 cp "s3://${dep_bucket}/dcvserverinit" "${_dir}/dcvserverinit"

yum -y update --skip-broken
yum -y install wget vim screen pciutils

has_nvidia_card=$(check_nvidia_card)

aws ec2 create-tags --resources ${instance} --tags "Key=Name,Value=${name} (installing Gnome)" --region $region

yum -y groupinstall "GNOME Desktop" --skip-broken
yum -y install xorg-x11-drv-dummy xorg-x11-server-utils

# The initial-setup display does not get registered on systemd
yum -y erase initial-setup
mkdir /etc/skel/.config/
echo "yes" > /etc/skel/.config/gnome-initial-setup-done

# Note handle firewalld after we install the workstation
systemctl disable firewalld
disable_selinux

arch=$(arch)
dcv_tgz="${dcv_pkg_name}-el7-${arch}.tgz"

aws s3 cp "s3://${dcv_bucket}/${dcv_tgz}" "${_dir}/${dcv_tgz}"
tar zxvf "${_dir}/${dcv_tgz}" -C "${_dir}/"
yum -y install "${_dir}"/nice-dcv-*/nice-dcv-server*.rpm "${_dir}"/nice-dcv-*/nice-dcv-gltest*.rpm

systemctl enable dcvserver.service

if [ "${has_nvidia_card}" = "Yes" ]; then
    if [ $(check_nouveau) = "Yes" ]; then
        disable_nouveau
    fi

    instance_type=$(curl http://169.254.169.254/latest/meta-data/instance-type)
    case "${instance_type}" in
    g3.* | g3s.* )
        download_nvidia_driver_for_g3
        ;;
    g4dn.* )
        download_nvidia_driver_for_g4
        ;;
    *)
        ;;
    esac
else
    aws s3 cp "s3://${dep_bucket}/xorg.conf" "${_dir}/xorg.conf"
    mv -fb "${_dir}/xorg.conf" /etc/X11/xorg.conf
fi

aws ec2 create-tags --resources ${instance} --tags "Key=Name,Value=${name} (installing software)" --region $region
yum install -y libpng12 mesa-libGLw libXp gamin audiofile audiofile-devel e2fsprogs-libs tcsh compat-libtiff3
yum install -y xorg-x11-fonts-ISO8859-1-100dpi xorg-x11-fonts-ISO8859-1-75dpi
yum install -y liberation-mono-fonts liberation-fonts-common liberation-sans-fonts liberation-serif-fonts
yum install -y https://download1.rpmfusion.org/free/el/rpmfusion-free-release-7.noarch.rpm
yum install -y vlc calligra-krita
wget https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
yum install -y ./google-chrome-stable_current_*.rpm
rm -f google-chrome-stable_current_*.rpm
aws ec2 create-tags --resources ${instance} --tags "Key=Name,Value=${name} (installing FSx Drivers)" --region $region

wget https://fsx-lustre-client-repo-public-keys.s3.amazonaws.com/fsx-rpm-public-key.asc -O /tmp/fsx-rpm-public-key.asc
rpm --import /tmp/fsx-rpm-public-key.asc
wget https://fsx-lustre-client-repo.s3.amazonaws.com/el/7/fsx-lustre-client.repo -O /etc/yum.repos.d/aws-fsx.repo
sed -i 's#7#7.8#' /etc/yum.repos.d/aws-fsx.repo
yum clean all
yum install -y kmod-lustre-client lustre-client

# add user
groupadd ${linux_user}
useradd ${linux_user} -m -g ${linux_user}
echo "${linux_user}:${linux_password}" | chpasswd
echo "Created user ${linux_user}"

aws ec2 create-tags --resources ${instance} --tags "Key=Name,Value=${name} (set fsx disk)" --region $region

attacheddisks=$(lsblk -o NAME,FSTYPE -dsn | awk '$2 == "" {print $1}')
disknum=1
for disk in $attacheddisks; do
  mkdir /mnt/nvme$disknum
  mkfs.xfs /dev/$disk
  echo "/dev/$disk  /mnt/nvme$disknum xfs defaults 0 0" >> /etc/fstab
  chown ${linux_user} /mnt/nvme$disknum -R
  ((disknum++))
done
mkdir /mnt/fsx
chown ${linux_user} /mnt/fsx -R

echo "${deploy_fsx}.fsx.$region.amazonaws.com@tcp:/${lustre_mount} /mnt/fsx lustre defaults,noatime,flock,_netdev 0 0" >> /etc/fstab
aws ec2 create-tags --resources ${instance} --tags "Key=Name,Value=${name} (fsx complete)" --region $region

# create startup script
cp "${_dir}/dcvserverinit" /etc/init.d/
chmod +x /etc/init.d/dcvserverinit
chkconfig --add dcvserverinit
echo "Enabled dcvserverinit service"

# write the config file
cat > /etc/dcv/dcv.conf << EOF
[session-management]
create-session=true
owner="${linux_user}"
EOF
echo "Created configuration file"

echo "Rebooting..."
aws ec2 create-tags --resources ${instance} --tags "Key=Name,Value=${name} (deployed)" --region $region
curl -X PUT -H 'Content-Type:' --data-binary '{"Status" : "SUCCESS","Reason" : "Deployment Complete","UniqueId" : "ID1234","Data" : "Deployment Complete"}' ${signal_url}
  
reboot

# ex:set ts=4 et:
