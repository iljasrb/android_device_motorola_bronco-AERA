#
#	This file is part of the AERA Recovery Project
#	Copyright (C) 2024-2026 The AERA Recovery Project
#
#	AERA is free software: you can redistribute it and/or modify
#	it under the terms of the GNU General Public License as published by
#	the Free Software Foundation, either version 3 of the License, or
#	(at your option) any later version.
#
#	AERA is distributed in the hope that it will be useful,
#	but WITHOUT ANY WARRANTY; without even the implied warranty of
#	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#	GNU General Public License for more details.
#
#	See <http://www.gnu.org/licenses/>.
#
FDEVICE="bronco"

aera_get_target_device() {
local chkdev=$(echo "$BASH_SOURCE" | grep -w $FDEVICE)
   if [ -n "$chkdev" ]; then
      AERA_BUILD_DEVICE="$FDEVICE"
   else
      chkdev=$(set | grep BASH_ARGV | grep -w $FDEVICE)
      [ -n "$chkdev" ] && AERA_BUILD_DEVICE="$FDEVICE"
   fi
}

if [ -z "$1" -a -z "$AERA_BUILD_DEVICE" ]; then
   aera_get_target_device
fi

if [ "$1" = "$FDEVICE" -o "$AERA_BUILD_DEVICE" = "$FDEVICE" ]; then
	export LC_ALL="C"
	export AERA_AB_DEVICE=1
	export AERA_VIRTUAL_AB_DEVICE=1
	export AERA_VANILLA_BUILD=1
	export AERA_USE_DMSETUP=1
	export AERA_PRODUCT_PREFIX=AERA
	export AERA_BUILD_STATUS=Unofficial
	# Beta, not Stable: Stable forces OF_ADVANCED_SECURITY, which disables
	# adb/MTP at boot until toggled in the UI.
	export AERA_BUILD_TYPE=Beta
	export AERA_ALLOW_EARLY_SETTINGS_LOAD=1
	unset AERA_MAINTAINER_PATCH_VERSION
fi
#
