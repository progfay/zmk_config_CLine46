/*
 * Copyright (c) 2026 progfay
 *
 * SPDX-License-Identifier: MIT
 */

#define DT_DRV_COMPAT cline46_behavior_local_morph

#include <zephyr/device.h>
#include <zephyr/logging/log.h>

#include <drivers/behavior.h>
#include <zmk/behavior.h>
#include <zmk/hid.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

// src/hid.c (and upstream behavior_mod_morph.c) is only compiled on the split central.
#if (!IS_ENABLED(CONFIG_ZMK_SPLIT) || IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_CENTRAL)) &&                \
    DT_HAS_COMPAT_STATUS_OKAY(DT_DRV_COMPAT)

/*
 * Copy of upstream behavior_mod_morph.c with one change: the masked modifiers
 * are cleared right after the morph binding's press, instead of on release.
 *
 * Upstream keeps the (global) HID mask until release, so with ctrl held,
 * `l` (morphed to RIGHT, ctrl masked) followed by `e` before releasing `l`
 * sends a plain `e` instead of ctrl+e. &kp raises its keycode event
 * synchronously and the HID report is copied into the endpoint queue
 * (hog.c k_msgq_put), so clearing the mask after invoke no longer affects the
 * press report but restores the modifiers for any key pressed afterwards.
 */

struct behavior_local_morph_config {
    struct zmk_behavior_binding normal_binding;
    struct zmk_behavior_binding morph_binding;
    zmk_mod_flags_t mods;
    zmk_mod_flags_t masked_mods;
};

struct behavior_local_morph_data {
    struct zmk_behavior_binding *pressed_binding;
};

static int on_local_morph_binding_pressed(struct zmk_behavior_binding *binding,
                                         struct zmk_behavior_binding_event event) {
    const struct device *dev = zmk_behavior_get_binding(binding->behavior_dev);
    const struct behavior_local_morph_config *cfg = dev->config;
    struct behavior_local_morph_data *data = dev->data;

    if (data->pressed_binding != NULL) {
        LOG_ERR("Can't press the same mod-morph twice");
        return -ENOTSUP;
    }

    if (!(zmk_hid_get_explicit_mods() & cfg->mods)) {
        data->pressed_binding = (struct zmk_behavior_binding *)&cfg->normal_binding;
        return zmk_behavior_invoke_binding(data->pressed_binding, event, true);
    }

    data->pressed_binding = (struct zmk_behavior_binding *)&cfg->morph_binding;
    zmk_hid_masked_modifiers_set(cfg->masked_mods);
    int err = zmk_behavior_invoke_binding(data->pressed_binding, event, true);
    zmk_hid_masked_modifiers_clear();
    return err;
}

static int on_local_morph_binding_released(struct zmk_behavior_binding *binding,
                                           struct zmk_behavior_binding_event event) {
    const struct device *dev = zmk_behavior_get_binding(binding->behavior_dev);
    struct behavior_local_morph_data *data = dev->data;

    if (data->pressed_binding == NULL) {
        LOG_ERR("Mod-morph already released");
        return -ENOTSUP;
    }

    struct zmk_behavior_binding *pressed_binding = data->pressed_binding;
    data->pressed_binding = NULL;
    return zmk_behavior_invoke_binding(pressed_binding, event, false);
}

static const struct behavior_driver_api behavior_local_morph_driver_api = {
    .binding_pressed = on_local_morph_binding_pressed,
    .binding_released = on_local_morph_binding_released,
#if IS_ENABLED(CONFIG_ZMK_BEHAVIOR_METADATA)
    .get_parameter_metadata = zmk_behavior_get_empty_param_metadata,
#endif
};

#define _TRANSFORM_ENTRY(idx, node)                                                                \
    {                                                                                              \
        .behavior_dev = DEVICE_DT_NAME(DT_INST_PHANDLE_BY_IDX(node, bindings, idx)),               \
        .param1 = COND_CODE_0(DT_INST_PHA_HAS_CELL_AT_IDX(node, bindings, idx, param1), (0),       \
                              (DT_INST_PHA_BY_IDX(node, bindings, idx, param1))),                  \
        .param2 = COND_CODE_0(DT_INST_PHA_HAS_CELL_AT_IDX(node, bindings, idx, param2), (0),       \
                              (DT_INST_PHA_BY_IDX(node, bindings, idx, param2))),                  \
    }

#define LOCAL_MORPH_INST(n)                                                                        \
    static const struct behavior_local_morph_config                                                \
        behavior_local_morph_config_##n = {                                                        \
            .normal_binding = _TRANSFORM_ENTRY(0, n),                                              \
            .morph_binding = _TRANSFORM_ENTRY(1, n),                                               \
            .mods = DT_INST_PROP(n, mods),                                                         \
            .masked_mods = COND_CODE_0(DT_INST_NODE_HAS_PROP(n, keep_mods),                        \
                                       (DT_INST_PROP(n, mods)),                                    \
                                       (DT_INST_PROP(n, mods) & ~DT_INST_PROP(n, keep_mods))),     \
    };                                                                                             \
    static struct behavior_local_morph_data behavior_local_morph_data_##n = {};                    \
    BEHAVIOR_DT_INST_DEFINE(n, NULL, NULL, &behavior_local_morph_data_##n,                         \
                            &behavior_local_morph_config_##n, POST_KERNEL,                         \
                            CONFIG_KERNEL_INIT_PRIORITY_DEFAULT,                                   \
                            &behavior_local_morph_driver_api);

DT_INST_FOREACH_STATUS_OKAY(LOCAL_MORPH_INST)

#endif
