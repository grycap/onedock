#!/bin/bash
#
# ONEDock - Docker support for ONE (as VMs)
# Copyright (C) Atos IT
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

DRIVER_PATH=$(dirname $0)
ONEDOCK_FOLDER=$DRIVER_PATH
source ${DRIVER_PATH}/../../onedock.sh
setup_wn
log_onedock_debug "$0 $@"
source ${DRIVER_PATH}/vmmfnc.sh

NAME=$1
SAVE_PATH=$2

mkdir -p $SAVE_PATH

log_onedock_debug $(docker checkpoint create --checkpoint-dir=$SAVE_PATH $NAME checkpoint-$NAME)
exit 0