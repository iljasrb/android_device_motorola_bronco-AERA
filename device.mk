#
# Copyright (C) 2024 The Android Open Source Project
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := device/motorola/bronco

PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_VIRTUAL_AB_OTA := true

# fastbootd
# The AOSP AIDL boot-control HAL reads /misc through libboot_control and lives
# entirely on /system, so fastbootd does not need the vendor boot HAL (or a
# mounted /vendor) to resolve the current slot.
PRODUCT_PACKAGES += \
    android.hardware.boot-service.default_recovery \
    android.hardware.fastboot@1.1-impl-mock \
    fastbootd

# Graphics bits the recovery ramdisk needs from the platform
TARGET_RECOVERY_DEVICE_MODULES += \
    libion \
    libdmabufheap

RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libion.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libdmabufheap.so

# Adreno's EGL initializes its Android platform subdriver even for pbuffer-only
# rendering. The subdriver (vendor blob) needs the platform native-window and
# mapper client APIs, so build the matching A16 libraries into the ramdisk
# instead of shipping the ROM's newer copies: the recovery binary already links
# this ramdisk's libc++, and a newer libui cannot resolve against it.
# std::__1::__hash_memory shim (gpu/) for the ROM's gralloc libraries.
TARGET_RECOVERY_DEVICE_MODULES += \
    libaera_gpu_compat \
    libui \
    libnativewindow \
    android.hardware.graphics.common-V6-ndk

RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libaera_gpu_compat.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libui.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libnativewindow.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/android.hardware.graphics.common-V6-ndk.so

# FUSE passthrough
PRODUCT_PROPERTY_OVERRIDES += \
    persist.sys.fuse.passthrough.enable=true

# AERA settings
$(call inherit-product, $(LOCAL_PATH)/aera_bronco.mk)
