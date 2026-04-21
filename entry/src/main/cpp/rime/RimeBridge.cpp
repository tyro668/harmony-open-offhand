#include "rime_bridge.h"

namespace offhand::rime {
std::string ProcessKeyJson(const std::string &session_id, int32_t key_code, int32_t modifier)
{
    return StringifyState(ProcessKey(session_id, key_code, modifier));
}

std::string GetStateJson(const std::string &session_id)
{
    return StringifyState(GetState(session_id));
}

std::string SelectCandidateJson(const std::string &session_id, int32_t index)
{
    return StringifyState(SelectCandidate(session_id, index));
}

std::string SetSchemaJson(const std::string &session_id, const std::string &schema_id)
{
    return StringifyState(SetSchema(session_id, schema_id));
}

std::string SetOptionJson(const std::string &session_id, const std::string &option_name, bool value)
{
    return StringifyState(SetOption(session_id, option_name, value));
}

std::string ClearCompositionJson(const std::string &session_id)
{
    return StringifyState(ClearComposition(session_id));
}

std::string CommitCompositionJson(const std::string &session_id)
{
    return StringifyState(CommitComposition(session_id));
}

std::string SetInputJson(const std::string &session_id, const std::string &input)
{
    return StringifyState(SetInput(session_id, input));
}

std::string PageUpJson(const std::string &session_id)
{
    return StringifyState(PageUp(session_id));
}

std::string PageDownJson(const std::string &session_id)
{
    return StringifyState(PageDown(session_id));
}
} // namespace offhand::rime
