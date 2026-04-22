#ifndef OFFHAND_RIME_BRIDGE_H
#define OFFHAND_RIME_BRIDGE_H

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace offhand::rime {
struct Candidate {
    int32_t index = 0;
    std::string text;
    std::string comment;
    std::string label;
    bool highlighted = false;
};

struct State {
    std::string schema_id;
    std::string raw_input;
    std::string composing_text;
    std::string commit_text;
    std::vector<Candidate> candidates;
    bool is_ascii_mode = false;
    std::unordered_map<std::string, bool> options;
    int32_t page_size = 0;
    int32_t page_no = 0;
    bool is_last_page = true;
    int32_t highlighted_candidate_index = -1;
    std::string select_keys;
};

std::string Init(const std::string &shared_data_dir, const std::string &user_data_dir);
std::string DeployIfNeeded();
std::string CreateSession(const std::string &schema_id);
void DestroySession(const std::string &session_id);
bool FindSession(const std::string &session_id);
State ProcessKey(const std::string &session_id, int32_t key_code, int32_t modifier);
State GetState(const std::string &session_id);
State SelectCandidate(const std::string &session_id, int32_t index);
State SetSchema(const std::string &session_id, const std::string &schema_id);
State SetOption(const std::string &session_id, const std::string &option_name, bool value);
State ClearComposition(const std::string &session_id);
State CommitComposition(const std::string &session_id);
State SetInput(const std::string &session_id, const std::string &input);
State PageUp(const std::string &session_id);
State PageDown(const std::string &session_id);
std::string SyncUserData();

std::string StringifyStatus(bool ok, const std::string &message);
std::string StringifyState(const State &state);

std::string ProcessKeyJson(const std::string &session_id, int32_t key_code, int32_t modifier);
std::string GetStateJson(const std::string &session_id);
std::string SelectCandidateJson(const std::string &session_id, int32_t index);
std::string SetSchemaJson(const std::string &session_id, const std::string &schema_id);
std::string SetOptionJson(const std::string &session_id, const std::string &option_name, bool value);
std::string ClearCompositionJson(const std::string &session_id);
std::string CommitCompositionJson(const std::string &session_id);
std::string SetInputJson(const std::string &session_id, const std::string &input);
std::string PageUpJson(const std::string &session_id);
std::string PageDownJson(const std::string &session_id);
} // namespace offhand::rime

#endif
