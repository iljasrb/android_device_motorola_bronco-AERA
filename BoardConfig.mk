#
# Copyright (C) 2024 The Android Open Source Project
#
# SPDX-License-Identifier: Apache-2.0
#

DEVICE_PATH := device/motorola/bronco

ALLOW_MISSING_DEPENDENCIES := true

# Platform / SoC (SM8475, waipio family)
TARGET_BOARD_PLATFORM := taro
TARGET_BOARD_PLATFORM_GPU := qcom-adreno730
QCOM_BOARD_PLATFORMS += taro

# Architecture
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a-dotprod
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 :=
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := kryo385

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-2a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := kryo385

TARGET_USES_UEFI := true
ENABLE_CPUSETS := true
ENABLE_SCHEDBOOST := true

# Bootloader
BOARD_VENDOR := motorola
TARGET_BOOTLOADER_BOARD_NAME := bronco
TARGET_NO_BOOTLOADER := true
TARGET_NO_RADIOIMAGE := true
TARGET_OTA_ASSERT_DEVICE := bronco

# Kernel
BOARD_BOOT_HEADER_VERSION := 4
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)
# build-recoveryimage-target does NOT read BOARD_MKBOOTIMG_ARGS; without this
# the image comes out header v0 and the bootloader rejects it.
BOARD_RECOVERY_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)
BOARD_HEADER_SIZE := 1584
BOARD_KERNEL_BASE := 0x00000000
BOARD_KERNEL_PAGESIZE := 4096
BOARD_KERNEL_IMAGE_NAME := kernel
BOARD_RAMDISK_USE_LZ4 := true
BOARD_USES_GENERIC_KERNEL_IMAGE := true
TARGET_KERNEL_ARCH := arm64

# Motorola ships the recovery partition as a ramdisk with no kernel of its own;
# the bootloader pairs it with the boot partition's kernel and the vendor_boot
# vendor ramdisk (which carries the kernel modules).
BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE := true

BOARD_BOOTCONFIG += \
    androidboot.hardware=qcom \
    androidboot.memcg=1 \
    androidboot.usbcontroller=a600000.dwc3

# Partitions
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += \
    boot \
    dtbo \
    product \
    recovery \
    system \
    system_ext \
    vbmeta \
    vbmeta_system \
    vendor \
    vendor_dlkm \
    vendor_boot

BOARD_BOOTIMAGE_PARTITION_SIZE := 100663296
BOARD_DTBOIMG_PARTITION_SIZE := 25165824
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 104857600
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 100663296
BOARD_FLASH_BLOCK_SIZE := 262144

BOARD_SUPER_PARTITION_SIZE := 7333740544
BOARD_SUPER_PARTITION_GROUPS := mot_dp_group
BOARD_MOT_DP_GROUP_SIZE := 7329546240
BOARD_MOT_DP_GROUP_PARTITION_LIST := product system system_ext vendor vendor_dlkm

# Filesystems
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_USES_VENDOR_DLKMIMAGE := true
BOARD_VENDOR_DLKMIMAGE_FILE_SYSTEM_TYPE := erofs
TARGET_COPY_OUT_VENDOR := vendor
TARGET_COPY_OUT_VENDOR_DLKM := vendor_dlkm
BOARD_USES_METADATA_PARTITION := true
TARGET_USES_MKE2FS := true

# Recovery
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery.fstab
TARGET_RECOVERY_QCOM_RTC_FIX := true
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
BOARD_HAS_NO_SELECT_BUTTON := true
RECOVERY_SDCARD_ON_DATA := true

# Decryption (FBE). The recovery runs the vendor's Android 16 TEE stack:
# qseecomd + AIDL keymint + HIDL gatekeeper + keystore2 + spdaemon/sec_nvm/SPU
# (see recovery/root/init.recovery.qcom.rc).
BOARD_USES_QCOM_FBE_DECRYPTION := true
AERA_INCLUDE_CRYPTO := true
AERA_INCLUDE_CRYPTO_FBE := true
AERA_INCLUDE_FBE_METADATA_DECRYPT := true

# The Motorola keymint service links the *_platform.so SONAMEs. AERA ships the
# frozen AIDL libs as -V1-ndk.so, so provide the platform aliases it looks for.
TARGET_RECOVERY_DEVICE_MODULES += android.hardware.security.keymint-V1-ndk
# keystore2 (which recovery's FBE decryption talks to) links libsqlite, but the
# prebuilt recovery lib list omits it.
RECOVERY_LIBRARY_SOURCE_FILES += $(TARGET_OUT_SHARED_LIBRARIES)/libsqlite.so
RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/android.hardware.security.keymint-V1-ndk.so
BOARD_RECOVERY_IMAGE_PREPARE += \
    rm -f $(TARGET_RECOVERY_ROOT_OUT)/system/etc/vintf/manifest/android.system.keystore2-service.xml; \
    cp -a -n $(TARGET_RECOVERY_ROOT_OUT)/vendor/lib64/*.so $(TARGET_RECOVERY_ROOT_OUT)/system/lib64/ 2>/dev/null || true; \
    cp -f $(TARGET_OUT_ETC)/task_profiles.json $(TARGET_RECOVERY_ROOT_OUT)/system/etc/task_profiles.json; \
    ln -sf android.hardware.gatekeeper@1.0-impl-qti.so $(TARGET_RECOVERY_ROOT_OUT)/vendor/lib64/hw/gatekeeper.default.so; \
    ln -sf android.hardware.gatekeeper@1.0-impl-qti.so $(TARGET_RECOVERY_ROOT_OUT)/vendor/lib64/hw/gatekeeper.qcom.so; \
    ln -sf android.hardware.gatekeeper@1.0-impl-qti.so $(TARGET_RECOVERY_ROOT_OUT)/vendor/lib64/hw/gatekeeper.taro.so; \
    mkdir -p $(TARGET_RECOVERY_ROOT_OUT)/system/lib64; \
    ln -sf android.hardware.security.keymint-V1-ndk.so $(TARGET_RECOVERY_ROOT_OUT)/system/lib64/android.hardware.security.keymint-V1-ndk_platform.so; \
    ln -sf android.hardware.security.secureclock-V1-ndk.so $(TARGET_RECOVERY_ROOT_OUT)/system/lib64/android.hardware.security.secureclock-V1-ndk_platform.so; \
    ln -sf android.hardware.security.sharedsecret-V1-ndk.so $(TARGET_RECOVERY_ROOT_OUT)/system/lib64/android.hardware.security.sharedsecret-V1-ndk_platform.so;

# Verified boot (unlocked bootloader; testkey is fine)
BOARD_AVB_ENABLE := true
BOARD_AVB_RECOVERY_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem
BOARD_AVB_RECOVERY_ALGORITHM := SHA256_RSA4096
BOARD_AVB_RECOVERY_ROLLBACK_INDEX := 1
BOARD_AVB_RECOVERY_ROLLBACK_INDEX_LOCATION := 1

# Android crypto / AVB hacks
# These are recovery-image placeholders, not the installed ROM's values.
# prepdecrypt.sh loads the real OS/security patch levels from /system and
# /vendor before keymint starts (see init.recovery.qcom.rc), because KeyMint
# uses the vendor patch level when it upgrades the metadata keyblob.
PLATFORM_SECURITY_PATCH := 2099-12-31
VENDOR_SECURITY_PATCH := 2099-12-31
PLATFORM_VERSION := 16.1.0

# AERA
AERA_THEME := portrait_hdpi
AERA_DEVICE_VERSION := ThinkPhone
AERA_SCREEN_BLANK_ON_BOOT := true
AERA_INPUT_BLACKLIST := "hbtp_vm"
# PM8350B HV haptics exposes FF_CONSTANT on /dev/input/event3; the kernel has
# no timed_output/vibrator device.
AERA_SUPPORT_INPUT_FF_HAPTICS := true
AERA_USE_TOOLBOX := true
AERA_EXCLUDE_APEX := true
AERA_NO_LEGACY_PROPS := true
AERA_NO_BIND_SYSTEM := true
AERA_INCLUDE_REPACKTOOLS := true
AERA_INCLUDE_LOGCAT := true
AERA_EXTRA_LANGUAGES := true
TARGET_USES_LOGD := true

# Early settings caches must live on a filesystem that is readable before the
# user unlocks CE storage. /data/recovery is device-encrypted storage: it is
# available as soon as metadata decryption mounts /data, unlike the default
# /data/media/0 fallback. Full preferences remain at
# /data/media/0/AERA/preferences.conf; keep the inherited tool/log home on the
# normal sdcard path, as the reference trees do when overriding this root.
AERA_SETTINGS_ROOT_DIRECTORY := /data/recovery
AERA_MISCELLANEOUS_ROOT_DIRECTORY := /sdcard

# bronco is A/B and also has a dedicated recovery partition.
AERA_AB_DEVICE_WITH_RECOVERY_PARTITION := 1
AERA_DEFAULT_KEYMASTER_VERSION := 4.1

# UI geometry (1080x2400). Adaptive scaling is the current AERA path; the
# status-bar metrics keep AERA's defaults.
AERA_SCREEN_H := 2400
AERA_UI_ADAPTIVE_RESOLUTION := true

# Brightness (panel0-backlight)
AERA_MAX_BRIGHTNESS := 4095
AERA_DEFAULT_BRIGHTNESS := 2048
AERA_BRIGHTNESS_PATH := "/sys/class/backlight/panel0-backlight/brightness"

# bronco has a configfs-only USB controller and no legacy android0 gadget, so
# TWRP's MTP cannot work here (/dev/mtp_usb is absent). init.recovery.qcom.rc
# collapses mtp,adb back to plain adb.
#
# The real /sys/class/power_supply/battery is registered by the ADSP charger
# stack; spss-start.sh boots the ADSP and mounts the modem firmware so the node
# appears and reports true capacity/charging state.
#
# AERA's backend tests this flag for the literal value 1 (not "true"), and no
# health HAL is registered in recovery, so keep it numeric.
AERA_USE_LEGACY_BATTERY_SERVICES := 1

# Flashlight: two nodes, ORDER MATTERS -- torch first, switch second.
# leds-qti-flash only lets qti_flash_switch_enable() act on a channel after a
# torch write marks it configured. bronco's DT wires the rear flash to channel
# 1 (pm8350c_flash1/torch1/switch1).
AERA_FL_PATH1 := /sys/class/leds/led:torch_1
AERA_FL_PATH2 := /sys/class/leds/led:switch_1

# WLAN in recovery (TWRP network UI + wpa_supplicant). The QCA6490 driver and
# firmware come from the vendor partitions; see docs/wifi-support.md.
AERA_ENABLE_WLAN := 1

# Root manager (KernelSU family). Packs /sbin/ksud, the bundled provider
# catalog (KernelSU, KernelSU Next, SukiSU Ultra LKMs) and the AERA Root
# Manager screen. The shinobu kernel already ships KernelSU support, so the
# manager reports the running kernel instead of offering a boot patch.
AERA_ENABLE_ROOT_MANAGER := 1
