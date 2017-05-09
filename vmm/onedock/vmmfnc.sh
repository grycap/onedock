#!/bin/bash
#
# ONEDock - Docker support for ONE (as VMs)
# Copyright (C) GRyCAP - I3M - UPV
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

function find_nbd {
    for device in /sys/class/block/nbd*; do
        if [ "$(cat $device/size)" == 0 ]; then
            DEV=/dev/$(basename $device)
            if [ -b "$DEV" ]; then
                echo "$DEV"
                break
            fi
        fi
    done
}

function setup_disk {
    FOLDER=$1
    DISK_ID=$2
    TARGET=$3
    DEVICES_FILE=$4
    CLEANUP_FILE=$5

    NBD_TGT=$(find_nbd)
    if [ "$NBD_TGT" == "" ]; then
        echo "could not find free devices to connect disk $DISK_ID"
        return 1
    fi

    log_onedock_debug "connecting disk $2 in $NBD_TGT"
    log_onedock_debug "qemu-nbd -c \"$NBD_TGT\" \"${FOLDER}/disk.${DISK_ID}\""
    sudo /usr/bin/qemu-nbd -c $NBD_TGT "${FOLDER}/disk.${DISK_ID}" 2> /dev/null
    if [ $? -ne 0 ]; then
        log_onedock_debug "FAILED: connecting disk $DISK_ID in $NBD_TGT"
        echo "could not connect the disk $DISK_ID"
        return 2
    fi

    cat >> "$CLEANUP_FILE" << EOT
sudo /usr/bin/qemu-nbd -d $NBD_TGT
EOT
    cat >> "$BOOTSTRAP_FILE" << EOT
        L_STRING=\$(udevadm test \$(readlink -f /sys/block/${TARGET}) 2> /dev/null | grep DEVLINKS)
        L_STRING=\${L_STRING:9}
        for L in \$L_STRING; do mkdir -p \$(dirname "\$L") && ln -s /dev/${TARGET} \$L; done
EOT

    echo "$NBD_TGT" >> "$DEVICES_FILE"
    EXPORTED_DEVICES="--device $NBD_TGT:/dev/$TARGET"
    DEVNAME=$(basename $NBD_TGT)
    PARTITIONS=$(ls -d /sys/class/block/${DEVNAME}/${DEVNAME}p* 2> /dev/null)
    if [ $? -eq 0 ]; then
        for partition in $PARTITIONS; do
            PARTITION_NAME=$(basename $partition)
            PARTITION_ID=${PARTITION_NAME##${DEVNAME}p}
            EXPORTED_DEVICES="${EXPORTED_DEVICES} --device \
                ${NBD_TGT}p${PARTITION_ID}:/dev/${TARGET}${PARTITION_ID}"
            cat >> "$BOOTSTRAP_FILE" << EOT
        L_STRING=\$(udevadm test \$(readlink -f /sys/block/${TARGET}/${TARGET}${PARTITION_ID}) 2> /dev/null | grep DEVLINKS)
        L_STRING=\${L_STRING:9}
        for L in \$L_STRING; do mkdir -p \$(dirname "\$L") && ln -s /dev/${TARGET}${PARTITION_ID} \$L; done
EOT
        done
    fi
    echo $EXPORTED_DEVICES
    return 0
}

function cleanup_disk {
    DEVICE=$1
    log_onedock_debug "asked to cleanup device $DEVICE"
    [ -b $DEVICE ] && log_onedock_debug "sudo /usr/bin/qemu-nbd -d $DEVICE" &&\
        sudo /usr/bin/qemu-nbd -d $DEVICE
}

function cleanup_disks {
    DOMXML=$1
    FOLDER=$2
    DEVICES_FILE=$3

    for device in $(cat $DEVICES_FILE); do
        cleanup_disk "$device"
    done
    return 0
}

function setup_devices {
    DOMXML=$1
    FOLDER=$2
    DEVICES_FILE=$3
    CLEANUP_FILE=$4
    BOOTSTRAP_FILE=$5
    ONEDOCK_CONTAINER_FOLDER=$6

    cat <<EOT > $DEVICES_FILE
EOT
    DEVICES_STR=
    DISKS="$(echo "$DOMXML" | xmlstarlet sel -t \
        -m /VM/TEMPLATE/DISK -v "concat(DISK_ID,';',TARGET,';',TYPE)" -n)"
    [ $? -ne 0 ] && echo "failed to parse domain" && return 1
    for DISK in $DISKS; do
        DISK_ID= TARGET= TYPE=
        IFS=';' read DISK_ID TARGET TYPE <<< "$DISK"

        # We'll skip disk 0, because it is the docker image
        [ "$DISK_ID" == "0" ] && continue

        RESULT=0
        if [ "$TYPE" == "fs" ] || [ "$TYPE" == "FILE" ]; then
            log_onedock_debug "setup_disk $FOLDER $DISK_ID $TARGET \
                $DEVICES_FILE $CLEANUP_FILE" "$BOOTSTRAP_FILE"
            CURRENT_DEVICE_STR=$(setup_disk "$FOLDER" "$DISK_ID" "$TARGET" \
                "$DEVICES_FILE" "$CLEANUP_FILE" "$BOOTSTRAP_FILE")
            RESULT=$?
        elif [ "$TYPE" == "CDROM" ]; then
            log_onedock_debug "setup_cd ${FOLDER}/disk.${DISK_ID} $TARGET \
                $CLEANUP_FILE $BOOTSTRAP_FILE"
            CURRENT_DEVICE_STR=$(setup_cd "${FOLDER}/disk.${DISK_ID}" \
                "$TARGET" "$CLEANUP_FILE" "$BOOTSTRAP_FILE")
            RESULT=$?
        else
            log_onedock_debug "FAILED: wrong type for disk $DISK_ID"
            error_message "we only support disks of type 'fs', 'FILE' and \
                'CDROM'... type '$TYPE' found"
            return 1
        fi

        if [ $RESULT -ne 0 ]; then
            log_onedock_debug "FAILED: could not setup disk \
                $DISK_ID ($CURRENT_DEVICE_STR)"
            error_message "could not setup disk $DISK_ID ($CURRENT_DEVICE_STR)"
            # This can be removed because cleaning up is now an integrated procedure
            # cleanup_disks "$DOMXML" "$FOLDER" "$DEVICES_FILE"
            return 2
        fi
        DEVICES_STR="$DEVICES_STR$CURRENT_DEVICE_STR "
    done

    echo $DEVICES_STR
    return 0
}

function setup_cd {
    ISOFILE=$1
    TARGET=$2
    CLEANUP_FILE=$3
    BOOTSTRAP_FILE=$4

    if [ "$ONEDOCK_PRIVILEGED" != "True" \
        -a "$ONEDOCK_SKIP_PRIVILEGED" == "True" ]; then
        log_onedock_debug "Skipping mounting $TARGET because cannot create \
            privileged containers and I am commited to avoid using it \
            (ONEDOCK_SKIP_PRIVILEGED)"
        return 0
    fi

    ISOFILE=$(readlink -f $ISOFILE)

    LOOP_DEVICE=$(sudo losetup -f --show "$ISOFILE" 2>&1)
    if [ $? -ne 0 ]; then
        log_onedock_debug "FAILED: to setup loop device for iso file $ISOFILE"
        error_message "failed to setup loop device for iso \
            file $ISOFILE ($LOOP_DEVICE)"
        return 1
    else
        echo "--privileged -v ${LOOP_DEVICE}:/dev/${TARGET}"
        # Old mechanism (when not needed privileged containers to mount loop devices)
        # echo "--privileged --device ${LOOP_DEVICE}:/dev/${TARGET}"
        cat >> "$CLEANUP_FILE" << EOT
sudo losetup -d $LOOP_DEVICE
EOT
        cat >> "$BOOTSTRAP_FILE" << EOT
        L_STRING=\$(udevadm test \$(readlink -f /sys/block/${TARGET}) 2> /dev/null | grep DEVLINKS)
        L_STRING=\${L_STRING:9}
        for L in \$L_STRING; do mkdir -p \$(dirname "\$L") && ln -s /dev/${TARGET} \$L; done
EOT
    fi
    return 0
}

function setup_context {
    DOMXML=$1
    FOLDER=$2
    CONTEXT_FILE=$3
    CLEANUP_FILE=$4
    BOOTSTRAP_FILE=$5
    ONEDOCK_CONTAINER_FOLDER=$6

    CONTEXT_STR=
    CONTEXT_DISK="$(echo "$DOMXML" | xmlstarlet sel -t \
        -m /VM/TEMPLATE/CONTEXT -v "concat(DISK_ID,';',TARGET)" -n)"
    DISK_ID= TARGET=
    IFS=';' read DISK_ID TARGET <<< "$CONTEXT_DISK"

    if [ "$DISK_ID" == "" ]; then
        return 0
    fi

    MOUNTFOLDER=${ONEDOCK_CONTAINER_FOLDER}/disk.${DISK_ID}.mountd
    S_ISOFILE=${FOLDER}/disk.${DISK_ID}
    S_ISOFILE=$(readlink -f $S_ISOFILE)
    D_ISOFILE=${ONEDOCK_CONTAINER_FOLDER}/disk.${DISK_ID}
    D_ISOFILE=$(readlink -f $D_ISOFILE)
    cp "$S_ISOFILE" "$D_ISOFILE"

    mkdir -p "$MOUNTFOLDER"
    log_onedock_debug "sudo mount -o loop ${D_ISOFILE} ${MOUNTFOLDER}"
    sudo mount -o loop "${D_ISOFILE}" "${MOUNTFOLDER}"
    if [ $? -ne 0 ]; then
        log_onedock_debug "FAILED: to mount $D_ISOFILE in $MOUNTFOLDER"
        error_message "FAILED to mount $D_ISOFILE in $MOUNTFOLDER"
        rm -f "${D_ISOFILE}"
        return 1
    fi

    CONTEXT_STR="-v ${MOUNTFOLDER}/:/mnt/"
    # Old mechanism (when not needed privileged containers to mount loop devices)
    # echo "--privileged --device ${LOOP_DEVICE}:/dev/${TARGET}"
    cat >> "$CLEANUP_FILE" << EOT
sudo umount ${MOUNTFOLDER}
rm -f "${D_ISOFILE}"
EOT

    echo "$CONTEXT_STR"
    return 0
}

function setup_network {
    DOMXML=$1
    FOLDER=$2
    NETWORKFILE=$3
    CLEANUP_FILE=$4
    BOOTSTRAP_FILE=$5
    ONEDOCK_CONTAINER_FOLDER=$6

    CONTNAME="one-$(echo "$DOMXML" | xmlstarlet sel -t -v /VM/ID)"

    cat <<EOT > $NETWORKFILE
EOT
    NICS="$(echo "$DOMXML" | xmlstarlet sel -t \
        -m /VM/TEMPLATE/NIC \
        -v "concat(NIC_ID,';',BRIDGE,';',IP,';',MAC,';',DNS)" -n)"

    G_DNS_STR=
    for NIC in $NICS; do
        NIC_ID= BRIDGE= IP= MAC=
        IFS=';' read NIC_ID BRIDGE IP MAC DNS <<< "$NIC"

        MAC_STR= IP_STR= BRIDGE_STR= GW_STR= DNS_STR=

        NICNAME=eth${NIC_ID}
        NIC_STR="--create-device $NICNAME"
        NIC_STR_UPDATE="--update-device $NICNAME"
        [ "$BRIDGE" != "" ] && BRIDGE_STR="--bridge $BRIDGE"
        [ "$MAC" != "" ] && MAC_STR="--mac $MAC"
        if [ "$IP" != "" ]; then
            [ "$ONEDOCK_DEFAULT_NETMASK" != "" ] && \
                IP=$IP/$ONEDOCK_DEFAULT_NETMASK
            IP_STR="--ip $IP"
        fi
        if [ "$DNS" != "" ]; then
            for D in $DNS; do
                DNS_STR="$DNS_STR --dns $D"
            done
        fi

        # Now we get the context for the network, to get the IP address
        NICNAME=ETH${NIC_ID}
        NET_CONTEXT="$(echo "$DOMXML" | xmlstarlet sel -t \
        -m /VM/TEMPLATE/CONTEXT -v "concat(${NICNAME}_IP,';',${NICNAME}_MAC,\
        ';',${NICNAME}_MASK,';',${NICNAME}_NETWORK,';',${NICNAME}_GATEWAY,\
        ';',${NICNAME}_DNS)")"

        if [ "$NET_CONTEXT" != "" ]; then
            # Initialize variables
            C_IP= C_MAC= C_MASK= C_NET= C_GW= C_DNS=
            IFS=';' read C_IP C_MAC C_MASK C_NET C_GW C_DNS <<< "$NET_CONTEXT"

            if [ "$C_IP" != "" ]; then
                if [ "$C_MASK" != "" ]; then
                    C_IP="${C_IP}/${C_MASK}"
                else
                    [ "$ONEDOCK_DEFAULT_NETMASK" != "" ] && \
                        C_IP="${C_IP}/${ONEDOCK_DEFAULT_NETMASK}"
                fi
                IP_STR="--ip $C_IP"
            fi

            [ "$C_MAC" != "" ] && MAC_STR="--mac $C_MAC"
            [ "$C_GW" != "" ] && GW_STR="--gateway $C_GW"

            if [ "$C_DNS" != "" ]; then
                # The context will override the DNS, because it should be
                # the same that what appears in the CD
                DNS_STR=
                for D in $C_DNS; do
                    DNS_STR="$DNS_STR --dns $D"
                done
            fi
        fi

        if [ "$DNS_STR" != "" ]; then
            G_DNS_STR="$G_DNS_STR $DNS_STR"
        fi

        # If there is a missing value, let's check if we should use DHCP
        USING_DHCP=False
        if [ "$IP_STR" == "" -o "$GW_STR" == "" ]; then
            if [ "$MAC_STR" != "" ]; then
                if is_true "$ONEDOCK_DEFAULT_DHCP"; then
                    USING_DHCP=True
                    IP_STR="--dhcp /var/run/dhclient.$CONTNAME-$NICNAME.pid"
                    IP_STR2="--release-dhcp /var/run/dhclient.\
                    $CONTNAME-$NICNAME.pid"
                    # IP_STR="--dhcp"
                    GW_STR=
                fi
            fi
        fi
        echo "$SUDO $DN --container-name $CONTAINERNAME \
            $BRIDGE_STR $MAC_STR $IP_STR $NIC_STR $GW_STR" >> $NETWORKFILE

        if [ "$USING_DHCP" == "True" ]; then
            echo "$SUDO $DN --container-name $CONTAINERNAME \
                $BRIDGE_STR $IP_STR2 $NIC_STR_UPDATE" >> $CLEANUP_FILE
        fi
    done

    if [ "$ONEDOCK_OVERRIDE_DNS" != "" ]; then
        for D in $ONEDOCK_OVERRIDE_DNS; do
            G_DNS_STR="$G_DNS_STR --dns $D"
        done
    fi

    echo "--net none -h $CONTAINERNAME \
                --add-host $CONTAINERNAME:127.0.1.1 $G_DNS_STR"
    return 0
}

function setup_vnc {
    DOMXML=$1
    CONTAINERNAME=$2

    IFS=';' read VNCPORT VNCPASSWD <<< "$(echo "$DOMXML" | \
        xmlstarlet sel -t -m /VM/TEMPLATE/GRAPHICS \
        -v "concat(PORT,';',PASSWD)" -n)"
    if [ "$VNCPORT" != "" ]; then
        if [ "$VNCPASSWD" == "" ]; then
            ( nohup bash -c "while [ \"\$(docker inspect \
                -f '{{.State.Status}}' $CONTAINERNAME)\" == \"running\" ]; do \
                echo 'respawning vnc term for $CONTAINERNAME'; \
                sudo /usr/bin/svncterm -timeout 0 -rfbport \"$VNCPORT\" \
                    -c docker exec -it \"$CONTAINERNAME\" /bin/bash; \
                done > /dev/null 2> /dev/null" )&
        else
            ( nohup bash -c "while [ \"\$(docker inspect \
                -f '{{.State.Status}}' $CONTAINERNAME)\" == \"running\" ]; do \
                echo 'respawning vnc term for $CONTAINERNAME'; \
                sudo /usr/bin/svncterm -timeout 0 \
                -passwd \"$VNCPASSWD\" -rfbport \"$VNCPORT\" \
                -c docker exec -it \"$CONTAINERNAME\" /bin/bash; \
                done > /dev/null 2> /dev/null" )&
        fi
    else
        log_onedock_debug "VNC is not defined for $CONTAINERNAME"
        return 1
    fi
    return 0
}

function exec_file {
    RESULT="$(bash -c "$(cat "$1")" ) 2>&1"
    RETVAL=$?

    if [ $RETVAL -ne 0 ]; then
        if [ "$2" != "" ]; then
            error_message "$2"
        else
            error_message "Failed execute file $1 ($RESULT)"
        fi
        return 1
    fi

    echo "$RESULT"
    return 0
}
