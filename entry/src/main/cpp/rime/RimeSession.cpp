#include "rime_bridge.h"

#include <X11/keysym.h>
#include <cstring>
#include <filesystem>
#include <functional>
#include <mutex>
#include <sstream>
#include <string>

#include <rime_api.h>

namespace {
constexpr const char *kExpectedSchemaId = "offhand_pinyin";

struct RuntimeState {
    std::mutex mutex;
    RimeApi *api = nullptr;
    std::string shared_data_dir;
    std::string user_data_dir;
    std::string prebuilt_data_dir;
    std::string staging_dir;
    std::string log_dir;
    bool initialized = false;
    bool deployed = false;
};

RuntimeState g_runtime;

std::string JsonEscape(const std::string &value)
{
    std::string escaped;
    escaped.reserve(value.size() + 16);
    for (char ch : value) {
        switch (ch) {
            case '\\':
                escaped += "\\\\";
                break;
            case '"':
                escaped += "\\\"";
                break;
            case '\n':
                escaped += "\\n";
                break;
            case '\r':
                escaped += "\\r";
                break;
            case '\t':
                escaped += "\\t";
                break;
            default:
                escaped.push_back(ch);
                break;
        }
    }
    return escaped;
}

RimeApi *GetApi()
{
    if (g_runtime.api == nullptr) {
        g_runtime.api = rime_get_api();
    }
    return g_runtime.api;
}

bool EnsureDirectory(const std::string &path, std::string &error_message)
{
    std::error_code error;
    std::filesystem::create_directories(path, error);
    if (!error) {
        return true;
    }
    error_message = error.message();
    return false;
}

void ResetPath(const std::string &path)
{
    if (path.empty()) {
        return;
    }
    std::error_code error;
    std::filesystem::remove_all(path, error);
    error.clear();
    std::filesystem::create_directories(path, error);
}

void RemoveFileIfExists(const std::string &path)
{
    if (path.empty()) {
        return;
    }
    std::error_code error;
    std::filesystem::remove(path, error);
}

bool ParseSessionId(const std::string &session_id, RimeSessionId &out)
{
    if (session_id.empty()) {
        return false;
    }
    try {
        out = static_cast<RimeSessionId>(std::stoull(session_id));
        return true;
    } catch (...) {
        return false;
    }
}

void FinalizeUnlocked()
{
    RimeApi *api = GetApi();
    if (!g_runtime.initialized || api == nullptr) {
        return;
    }
    if (RIME_API_AVAILABLE(api, cleanup_all_sessions)) {
        api->cleanup_all_sessions();
    }
    api->finalize();
    g_runtime.initialized = false;
    g_runtime.deployed = false;
}

void FillTraits(RimeTraits &traits)
{
    std::memset(&traits, 0, sizeof(RimeTraits));
    RIME_STRUCT_INIT(RimeTraits, traits);
    traits.shared_data_dir = g_runtime.shared_data_dir.c_str();
    traits.user_data_dir = g_runtime.user_data_dir.c_str();
    traits.distribution_name = "Offhand IME";
    traits.distribution_code_name = "offhand-ime";
    traits.distribution_version = "0.1.0";
    traits.app_name = "rime.offhand";
    traits.min_log_level = 2;
    traits.log_dir = g_runtime.log_dir.c_str();
    traits.prebuilt_data_dir = g_runtime.prebuilt_data_dir.c_str();
    traits.staging_dir = g_runtime.staging_dir.c_str();
}

std::string CollectSchemaListUnlocked(RimeApi *api)
{
    if (api == nullptr || !RIME_API_AVAILABLE(api, get_schema_list)) {
        return "";
    }
    RimeSchemaList schema_list = {0};
    if (!api->get_schema_list(&schema_list)) {
        return "";
    }
    std::string summary;
    for (size_t index = 0; index < schema_list.size; index++) {
        const char *schema_id = schema_list.list[index].schema_id != nullptr ? schema_list.list[index].schema_id : "";
        const char *schema_name = schema_list.list[index].name != nullptr ? schema_list.list[index].name : "";
        if (!summary.empty()) {
            summary += ",";
        }
        summary += schema_id;
        if (schema_name[0] != '\0') {
            summary += "/";
            summary += schema_name;
        }
    }
    api->free_schema_list(&schema_list);
    return summary;
}

bool HasSchemaUnlocked(RimeApi *api, const std::string &schema_id)
{
    if (schema_id.empty() || api == nullptr || !RIME_API_AVAILABLE(api, get_schema_list)) {
        return false;
    }
    RimeSchemaList schema_list = {0};
    if (!api->get_schema_list(&schema_list)) {
        return false;
    }
    bool found = false;
    for (size_t index = 0; index < schema_list.size; index++) {
        const char *current_schema_id = schema_list.list[index].schema_id;
        if (current_schema_id != nullptr && schema_id == current_schema_id) {
            found = true;
            break;
        }
    }
    api->free_schema_list(&schema_list);
    return found;
}

offhand::rime::State SnapshotStateUnlocked(RimeSessionId session_id);

bool ProbeSchemaUnlocked(RimeApi *api, const std::string &schema_id, std::string &probe_summary)
{
    if (api == nullptr) {
        probe_summary = "api=null";
        return false;
    }
    RimeSessionId session_id = api->create_session();
    if (!session_id) {
        probe_summary = "create_session failed";
        return false;
    }
    bool selected = schema_id.empty() || api->select_schema(session_id, schema_id.c_str());
    if (!selected) {
        api->destroy_session(session_id);
        probe_summary = "select_schema failed";
        return false;
    }
    api->set_option(session_id, "ascii_mode", False);
    api->clear_composition(session_id);
    constexpr char kProbeInput[] = "jijie";
    for (char ch : kProbeInput) {
        api->process_key(session_id, ch, 0);
    }
    offhand::rime::State state = SnapshotStateUnlocked(session_id);
    api->destroy_session(session_id);
    probe_summary = "raw=" + state.raw_input + ";preedit=" + state.composing_text +
        ";candidates=" + std::to_string(state.candidates.size());
    if (!state.candidates.empty()) {
        probe_summary += ";first=" + state.candidates.front().text;
    }
    return !state.candidates.empty();
}

bool RepairDeploymentUnlocked(RimeApi *api, std::string &repair_summary)
{
    ResetPath(g_runtime.prebuilt_data_dir);
    ResetPath(g_runtime.staging_dir);
    RemoveFileIfExists(g_runtime.user_data_dir + "/installation.yaml");
    std::string failure_reason;
    bool deployed = false;
    if (RIME_API_AVAILABLE(api, deploy)) {
        deployed = api->deploy() == True;
        if (!deployed) {
            failure_reason = "deploy() returned false";
        }
    }
    if (!deployed && RIME_API_AVAILABLE(api, start_maintenance)) {
        deployed = api->start_maintenance(True) == True;
        if (deployed && RIME_API_AVAILABLE(api, join_maintenance_thread)) {
            api->join_maintenance_thread();
        }
        if (!deployed) {
            failure_reason = "start_maintenance(True) returned false";
        }
    }
    if (deployed && !HasSchemaUnlocked(api, kExpectedSchemaId) && RIME_API_AVAILABLE(api, deploy_schema)) {
        deployed = api->deploy_schema("offhand_pinyin.schema.yaml") == True;
        if (!deployed) {
            failure_reason = "deploy_schema(offhand_pinyin.schema.yaml) returned false";
        }
    }
    if (!deployed) {
        repair_summary = failure_reason;
        return false;
    }
    repair_summary = "repair deploy ok";
    return true;
}

offhand::rime::State SnapshotStateUnlocked(RimeSessionId session_id)
{
    offhand::rime::State state;
    state.schema_id = "offhand_pinyin";
    state.options["ascii_mode"] = false;
    state.options["full_shape"] = false;
    state.page_size = 0;
    state.page_no = 0;
    state.is_last_page = true;
    state.highlighted_candidate_index = -1;

    RimeApi *api = GetApi();
    if (api == nullptr || !api->find_session(session_id)) {
        return state;
    }

    const char *raw_input = api->get_input(session_id);
    if (raw_input != nullptr) {
        state.raw_input = raw_input;
    }

    char schema_id_buffer[128] = {0};
    if (api->get_current_schema(session_id, schema_id_buffer, sizeof(schema_id_buffer)) && schema_id_buffer[0] != '\0') {
        state.schema_id = schema_id_buffer;
    }

    RIME_STRUCT(RimeStatus, status);
    if (api->get_status(session_id, &status)) {
        if (status.schema_id != nullptr && status.schema_id[0] != '\0') {
            state.schema_id = status.schema_id;
        }
        state.is_ascii_mode = status.is_ascii_mode == True;
        state.options["ascii_mode"] = status.is_ascii_mode == True;
        state.options["full_shape"] = status.is_full_shape == True;
        api->free_status(&status);
    }

    RIME_STRUCT(RimeContext, context);
    if (api->get_context(session_id, &context)) {
        if (context.composition.preedit != nullptr) {
            state.composing_text = context.composition.preedit;
        }
        if (context.menu.select_keys != nullptr) {
            state.select_keys = context.menu.select_keys;
        }
        state.page_size = context.menu.page_size;
        state.page_no = context.menu.page_no;
        state.is_last_page = context.menu.is_last_page == True;
        state.highlighted_candidate_index = context.menu.highlighted_candidate_index;
        for (int index = 0; index < context.menu.num_candidates; index++) {
            offhand::rime::Candidate candidate;
            candidate.index = index;
            if (context.menu.candidates[index].text != nullptr) {
                candidate.text = context.menu.candidates[index].text;
            }
            if (context.menu.candidates[index].comment != nullptr) {
                candidate.comment = context.menu.candidates[index].comment;
            }
            if (context.select_labels != nullptr && context.select_labels[index] != nullptr) {
                candidate.label = context.select_labels[index];
            } else if (context.menu.select_keys != nullptr &&
                static_cast<size_t>(index) < std::strlen(context.menu.select_keys)) {
                candidate.label = context.menu.select_keys[index];
            } else {
                candidate.label = std::to_string(index + 1);
            }
            candidate.highlighted = index == context.menu.highlighted_candidate_index;
            state.candidates.push_back(candidate);
        }
        api->free_context(&context);
    }

    RIME_STRUCT(RimeCommit, commit);
    if (api->get_commit(session_id, &commit)) {
        if (commit.text != nullptr) {
            state.commit_text = commit.text;
        }
        api->free_commit(&commit);
    }
    return state;
}

offhand::rime::State EmptyStateForInvalidSession()
{
    offhand::rime::State state;
    state.schema_id = "offhand_pinyin";
    state.options["ascii_mode"] = false;
    state.options["full_shape"] = false;
    state.page_size = 0;
    state.page_no = 0;
    state.is_last_page = true;
    state.highlighted_candidate_index = -1;
    return state;
}

int32_t NormalizeKeyCode(int32_t key_code)
{
    switch (key_code) {
        case 8:
            return XK_BackSpace;
        case 9:
            return XK_Tab;
        case 10:
        case 13:
            return XK_Return;
        case 27:
            return XK_Escape;
        default:
            return key_code;
    }
}

offhand::rime::State StateForSessionOperation(const std::string &session_id,
    const std::function<void(RimeApi *, RimeSessionId)> &operation)
{
    std::lock_guard<std::mutex> lock(g_runtime.mutex);
    RimeApi *api = GetApi();
    if (api == nullptr) {
        return EmptyStateForInvalidSession();
    }
    RimeSessionId parsed_session_id = 0;
    if (!ParseSessionId(session_id, parsed_session_id) || !api->find_session(parsed_session_id)) {
        return EmptyStateForInvalidSession();
    }
    operation(api, parsed_session_id);
    return SnapshotStateUnlocked(parsed_session_id);
}
} // namespace

namespace offhand::rime {
std::string Init(const std::string &shared_data_dir, const std::string &user_data_dir)
{
    std::lock_guard<std::mutex> lock(g_runtime.mutex);
    std::string error_message;
    if (!EnsureDirectory(shared_data_dir, error_message)) {
        return StringifyStatus(false, "failed to prepare shared data dir: " + error_message);
    }
    if (!EnsureDirectory(user_data_dir, error_message)) {
        return StringifyStatus(false, "failed to prepare user data dir: " + error_message);
    }

    std::string next_prebuilt_dir = shared_data_dir + "/build";
    std::string next_staging_dir = user_data_dir + "/build";
    std::string next_log_dir = user_data_dir + "/logs";
    if (!EnsureDirectory(next_prebuilt_dir, error_message)) {
        return StringifyStatus(false, "failed to prepare prebuilt data dir: " + error_message);
    }
    if (!EnsureDirectory(next_staging_dir, error_message)) {
        return StringifyStatus(false, "failed to prepare staging dir: " + error_message);
    }
    if (!EnsureDirectory(next_log_dir, error_message)) {
        return StringifyStatus(false, "failed to prepare log dir: " + error_message);
    }

    bool needs_reinitialize = !g_runtime.initialized ||
        g_runtime.shared_data_dir != shared_data_dir ||
        g_runtime.user_data_dir != user_data_dir;
    g_runtime.shared_data_dir = shared_data_dir;
    g_runtime.user_data_dir = user_data_dir;
    g_runtime.prebuilt_data_dir = next_prebuilt_dir;
    g_runtime.staging_dir = next_staging_dir;
    g_runtime.log_dir = next_log_dir;

    RimeApi *api = GetApi();
    if (api == nullptr) {
        return StringifyStatus(false, "failed to acquire rime api");
    }

    if (needs_reinitialize) {
        FinalizeUnlocked();
        RIME_STRUCT(RimeTraits, traits);
        FillTraits(traits);
        api->setup(&traits);
        api->initialize(nullptr);
        g_runtime.initialized = true;
        g_runtime.deployed = false;
    }
    return StringifyStatus(true, "initialized");
}

std::string DeployIfNeeded()
{
    std::lock_guard<std::mutex> lock(g_runtime.mutex);
    RimeApi *api = GetApi();
    if (!g_runtime.initialized || api == nullptr) {
        return StringifyStatus(false, "bridge not initialized");
    }
    if (!g_runtime.deployed) {
        bool deployed = false;
        std::string failure_reason;
        if (RIME_API_AVAILABLE(api, deploy)) {
            deployed = api->deploy() == True;
            if (!deployed) {
                failure_reason = "deploy() returned false";
            }
        }
        if (!deployed && RIME_API_AVAILABLE(api, start_maintenance)) {
            deployed = api->start_maintenance(True) == True;
            if (deployed && RIME_API_AVAILABLE(api, join_maintenance_thread)) {
                api->join_maintenance_thread();
            }
            if (!deployed) {
                failure_reason = "start_maintenance(True) returned false";
            }
        }
        if (deployed && !HasSchemaUnlocked(api, kExpectedSchemaId) &&
            RIME_API_AVAILABLE(api, deploy_schema)) {
            deployed = api->deploy_schema("offhand_pinyin.schema.yaml") == True;
            if (!deployed) {
                failure_reason = "deploy_schema(offhand_pinyin.schema.yaml) returned false";
            }
        }
        std::string schema_list = CollectSchemaListUnlocked(api);
        if (!deployed) {
            return StringifyStatus(false, failure_reason + "; schemas=" + schema_list);
        }
        if (!HasSchemaUnlocked(api, kExpectedSchemaId)) {
            return StringifyStatus(false, "expected schema missing after deploy; schemas=" + schema_list);
        }
        std::string probe_summary;
        if (!ProbeSchemaUnlocked(api, kExpectedSchemaId, probe_summary)) {
            std::string repair_summary;
            if (!RepairDeploymentUnlocked(api, repair_summary)) {
                return StringifyStatus(false, "schema probe failed (" + probe_summary + "); repair failed: " +
                    repair_summary + "; schemas=" + CollectSchemaListUnlocked(api));
            }
            schema_list = CollectSchemaListUnlocked(api);
            if (!HasSchemaUnlocked(api, kExpectedSchemaId)) {
                return StringifyStatus(false, "expected schema missing after repair; schemas=" + schema_list);
            }
            if (!ProbeSchemaUnlocked(api, kExpectedSchemaId, probe_summary)) {
                return StringifyStatus(false, "schema probe failed after repair: " + probe_summary +
                    "; schemas=" + schema_list);
            }
        }
        g_runtime.deployed = true;
        return StringifyStatus(true, "deploy-ready; schemas=" + schema_list);
    }
    return StringifyStatus(true, "deploy-ready");
}

std::string CreateSession(const std::string &schema_id)
{
    std::lock_guard<std::mutex> lock(g_runtime.mutex);
    RimeApi *api = GetApi();
    if (!g_runtime.initialized || api == nullptr) {
        return "";
    }
    RimeSessionId session_id = api->create_session();
    if (!session_id) {
        return "";
    }
    if (!schema_id.empty()) {
        if (!api->select_schema(session_id, schema_id.c_str())) {
            api->destroy_session(session_id);
            return "";
        }
    }
    return std::to_string(static_cast<unsigned long long>(session_id));
}

void DestroySession(const std::string &session_id)
{
    std::lock_guard<std::mutex> lock(g_runtime.mutex);
    RimeApi *api = GetApi();
    if (api == nullptr) {
        return;
    }
    RimeSessionId parsed_session_id = 0;
    if (!ParseSessionId(session_id, parsed_session_id) || !api->find_session(parsed_session_id)) {
        return;
    }
    api->destroy_session(parsed_session_id);
}

State ProcessKey(const std::string &session_id, int32_t key_code, int32_t modifier)
{
    return StateForSessionOperation(session_id, [key_code, modifier](RimeApi *api, RimeSessionId parsed_session_id) {
        api->process_key(parsed_session_id, NormalizeKeyCode(key_code), modifier);
    });
}

State GetState(const std::string &session_id)
{
    return StateForSessionOperation(session_id, [](RimeApi *, RimeSessionId) {
    });
}

State SelectCandidate(const std::string &session_id, int32_t index)
{
    return StateForSessionOperation(session_id, [index](RimeApi *api, RimeSessionId parsed_session_id) {
        if (index < 0) {
            return;
        }
        api->select_candidate_on_current_page(parsed_session_id, static_cast<size_t>(index));
    });
}

State SetSchema(const std::string &session_id, const std::string &schema_id)
{
    return StateForSessionOperation(session_id, [&schema_id](RimeApi *api, RimeSessionId parsed_session_id) {
        if (!schema_id.empty()) {
            api->select_schema(parsed_session_id, schema_id.c_str());
        }
    });
}

State SetOption(const std::string &session_id, const std::string &option_name, bool value)
{
    return StateForSessionOperation(session_id, [&option_name, value](RimeApi *api, RimeSessionId parsed_session_id) {
        api->set_option(parsed_session_id, option_name.c_str(), value ? True : False);
    });
}

State ClearComposition(const std::string &session_id)
{
    return StateForSessionOperation(session_id, [](RimeApi *api, RimeSessionId parsed_session_id) {
        api->clear_composition(parsed_session_id);
    });
}

State CommitComposition(const std::string &session_id)
{
    return StateForSessionOperation(session_id, [](RimeApi *api, RimeSessionId parsed_session_id) {
        api->commit_composition(parsed_session_id);
    });
}

State SetInput(const std::string &session_id, const std::string &input)
{
    return StateForSessionOperation(session_id, [&input](RimeApi *api, RimeSessionId parsed_session_id) {
        api->set_input(parsed_session_id, input.c_str());
    });
}

State PageUp(const std::string &session_id)
{
    return StateForSessionOperation(session_id, [](RimeApi *api, RimeSessionId parsed_session_id) {
        api->process_key(parsed_session_id, XK_Page_Up, 0);
    });
}

State PageDown(const std::string &session_id)
{
    return StateForSessionOperation(session_id, [](RimeApi *api, RimeSessionId parsed_session_id) {
        api->process_key(parsed_session_id, XK_Page_Down, 0);
    });
}

std::string SyncUserData()
{
    std::lock_guard<std::mutex> lock(g_runtime.mutex);
    RimeApi *api = GetApi();
    if (!g_runtime.initialized || api == nullptr) {
        return StringifyStatus(false, "bridge not initialized");
    }
    return StringifyStatus(api->sync_user_data() == True, "sync-complete");
}

std::string StringifyStatus(bool ok, const std::string &message)
{
    return std::string("{\"ok\":") + (ok ? "true" : "false") + ",\"message\":\"" + JsonEscape(message) + "\"}";
}

std::string StringifyState(const State &state)
{
    std::string json = "{";
    json += "\"schemaId\":\"" + JsonEscape(state.schema_id) + "\",";
    json += "\"rawInput\":\"" + JsonEscape(state.raw_input) + "\",";
    json += "\"composingText\":\"" + JsonEscape(state.composing_text) + "\",";
    json += "\"commitText\":\"" + JsonEscape(state.commit_text) + "\",";
    json += "\"candidates\":[";
    for (size_t index = 0; index < state.candidates.size(); index++) {
        if (index > 0) {
            json += ",";
        }
        json += "{";
        json += "\"index\":" + std::to_string(state.candidates[index].index) + ",";
        json += "\"text\":\"" + JsonEscape(state.candidates[index].text) + "\",";
        json += "\"comment\":\"" + JsonEscape(state.candidates[index].comment) + "\",";
        json += "\"label\":\"" + JsonEscape(state.candidates[index].label) + "\",";
        json += "\"highlighted\":" + std::string(state.candidates[index].highlighted ? "true" : "false");
        json += "}";
    }
    json += "],";
    json += "\"isAsciiMode\":" + std::string(state.is_ascii_mode ? "true" : "false") + ",";
    json += "\"pageSize\":" + std::to_string(state.page_size) + ",";
    json += "\"pageNo\":" + std::to_string(state.page_no) + ",";
    json += "\"isLastPage\":" + std::string(state.is_last_page ? "true" : "false") + ",";
    json += "\"highlightedCandidateIndex\":" + std::to_string(state.highlighted_candidate_index) + ",";
    json += "\"selectKeys\":\"" + JsonEscape(state.select_keys) + "\",";
    json += "\"options\":{";
    bool first_option = true;
    for (const auto &entry : state.options) {
        if (!first_option) {
            json += ",";
        }
        first_option = false;
        json += "\"" + JsonEscape(entry.first) + "\":" + std::string(entry.second ? "true" : "false");
    }
    json += "}";
    json += "}";
    return json;
}
} // namespace offhand::rime
