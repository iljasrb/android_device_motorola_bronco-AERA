#
# Copyright (C) 2024 The Android Open Source Project
#
# SPDX-License-Identifier: Apache-2.0
#

# AOSP base
$(call inherit-product, $(SRC_TARGET_DIR)/product/base.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/emulated_storage.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Recovery common
$(call inherit-product, vendor/twrp/config/common.mk)

# Device
$(call inherit-product, device/motorola/bronco/device.mk)

PRODUCT_PLATFORM := taro

# bronco uses 4 KB kernel pages; allow 4 KB-aligned prebuilts (magiskboot etc.).
PRODUCT_MAX_PAGE_SIZE_SUPPORTED := 4096
PRODUCT_RELEASE_NAME := bronco
PRODUCT_DEVICE := bronco
PRODUCT_NAME := twrp_bronco
PRODUCT_BRAND := motorola
PRODUCT_MODEL := ThinkPhone by motorola
PRODUCT_MANUFACTURER := motorola
PRODUCT_GMS_CLIENTID_BASE := android-motorola

# Recovery-only builds ship no usable kernel image metadata.
PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false

PRODUCT_BUILD_PROP_OVERRIDES += \
    PRIVATE_BUILD_DESC="bronco-user 12 T3TBS33.2-47-2-4 d290d release-keys"

BUILD_FINGERPRINT := motorola/bronco/bronco:12/T3TBS33.2-47-2-4/d290d:user/release-keys
