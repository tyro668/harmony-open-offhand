#include <napi/native_api.h>

#include <string>

#include "rime/rime_bridge.h"

namespace {
bool ReadStringArg(napi_env env, napi_value value, std::string &out)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }
    std::string buffer(length + 1, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied) != napi_ok) {
        return false;
    }
    out.assign(buffer.c_str(), copied);
    return true;
}

bool ReadInt32Arg(napi_env env, napi_value value, int32_t &out)
{
    return napi_get_value_int32(env, value, &out) == napi_ok;
}

bool ReadBoolArg(napi_env env, napi_value value, bool &out)
{
    return napi_get_value_bool(env, value, &out) == napi_ok;
}

napi_value CreateUtf8(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

napi_value InitBridge(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string shared_data_dir;
    std::string user_data_dir;
    if (argc < 2 || !ReadStringArg(env, args[0], shared_data_dir) || !ReadStringArg(env, args[1], user_data_dir)) {
        napi_throw_type_error(env, nullptr, "init expects sharedDataDir and userDataDir");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::Init(shared_data_dir, user_data_dir));
}

napi_value DeployIfNeeded(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateUtf8(env, offhand::rime::DeployIfNeeded());
}

napi_value CreateSession(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string schema_id;
    if (argc < 1 || !ReadStringArg(env, args[0], schema_id)) {
        napi_throw_type_error(env, nullptr, "createSession expects schemaId");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::CreateSession(schema_id));
}

napi_value DestroySession(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    if (argc < 1 || !ReadStringArg(env, args[0], session_id)) {
        napi_throw_type_error(env, nullptr, "destroySession expects sessionId");
        return nullptr;
    }
    offhand::rime::DestroySession(session_id);
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

napi_value FindSession(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    if (argc < 1 || !ReadStringArg(env, args[0], session_id)) {
        napi_throw_type_error(env, nullptr, "findSession expects sessionId");
        return nullptr;
    }
    bool exists = offhand::rime::FindSession(session_id);
    napi_value result = nullptr;
    napi_get_boolean(env, exists, &result);
    return result;
}

napi_value ProcessKey(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    int32_t key_code = 0;
    int32_t modifier = 0;
    if (argc < 3 || !ReadStringArg(env, args[0], session_id) || !ReadInt32Arg(env, args[1], key_code) ||
        !ReadInt32Arg(env, args[2], modifier)) {
        napi_throw_type_error(env, nullptr, "processKey expects sessionId, keyCode, modifier");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::ProcessKeyJson(session_id, key_code, modifier));
}

napi_value GetState(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    if (argc < 1 || !ReadStringArg(env, args[0], session_id)) {
        napi_throw_type_error(env, nullptr, "getState expects sessionId");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::GetStateJson(session_id));
}

napi_value SelectCandidate(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    int32_t index = 0;
    if (argc < 2 || !ReadStringArg(env, args[0], session_id) || !ReadInt32Arg(env, args[1], index)) {
        napi_throw_type_error(env, nullptr, "selectCandidate expects sessionId and index");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::SelectCandidateJson(session_id, index));
}

napi_value SetSchema(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    std::string schema_id;
    if (argc < 2 || !ReadStringArg(env, args[0], session_id) || !ReadStringArg(env, args[1], schema_id)) {
        napi_throw_type_error(env, nullptr, "setSchema expects sessionId and schemaId");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::SetSchemaJson(session_id, schema_id));
}

napi_value SetOption(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    std::string option_name;
    bool value = false;
    if (argc < 3 || !ReadStringArg(env, args[0], session_id) || !ReadStringArg(env, args[1], option_name) ||
        !ReadBoolArg(env, args[2], value)) {
        napi_throw_type_error(env, nullptr, "setOption expects sessionId, optionName, value");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::SetOptionJson(session_id, option_name, value));
}

napi_value ClearComposition(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    if (argc < 1 || !ReadStringArg(env, args[0], session_id)) {
        napi_throw_type_error(env, nullptr, "clearComposition expects sessionId");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::ClearCompositionJson(session_id));
}

napi_value CommitComposition(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    if (argc < 1 || !ReadStringArg(env, args[0], session_id)) {
        napi_throw_type_error(env, nullptr, "commitComposition expects sessionId");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::CommitCompositionJson(session_id));
}

napi_value SetInput(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    std::string input;
    if (argc < 2 || !ReadStringArg(env, args[0], session_id) || !ReadStringArg(env, args[1], input)) {
        napi_throw_type_error(env, nullptr, "setInput expects sessionId and input");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::SetInputJson(session_id, input));
}

napi_value PageUp(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    if (argc < 1 || !ReadStringArg(env, args[0], session_id)) {
        napi_throw_type_error(env, nullptr, "pageUp expects sessionId");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::PageUpJson(session_id));
}

napi_value PageDown(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string session_id;
    if (argc < 1 || !ReadStringArg(env, args[0], session_id)) {
        napi_throw_type_error(env, nullptr, "pageDown expects sessionId");
        return nullptr;
    }
    return CreateUtf8(env, offhand::rime::PageDownJson(session_id));
}

napi_value SyncUserData(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateUtf8(env, offhand::rime::SyncUserData());
}
} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "init", nullptr, InitBridge, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "deployIfNeeded", nullptr, DeployIfNeeded, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "createSession", nullptr, CreateSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "destroySession", nullptr, DestroySession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "findSession", nullptr, FindSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "processKey", nullptr, ProcessKey, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getState", nullptr, GetState, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "selectCandidate", nullptr, SelectCandidate, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setSchema", nullptr, SetSchema, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setOption", nullptr, SetOption, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "clearComposition", nullptr, ClearComposition, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "commitComposition", nullptr, CommitComposition, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setInput", nullptr, SetInput, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pageUp", nullptr, PageUp, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pageDown", nullptr, PageDown, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "syncUserData", nullptr, SyncUserData, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module entryModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&entryModule);
}
