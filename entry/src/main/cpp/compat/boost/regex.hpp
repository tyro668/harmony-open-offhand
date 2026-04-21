#ifndef OFFHAND_COMPAT_BOOST_REGEX_HPP
#define OFFHAND_COMPAT_BOOST_REGEX_HPP

#include <regex>
#include <string>
#include <utility>

namespace boost {
using regex_error = std::regex_error;
using smatch = std::smatch;
using cmatch = std::cmatch;
using sregex_iterator = std::sregex_iterator;

class regex {
public:
    regex() = default;

    regex(const char* pattern)
    {
        AssignPattern(pattern == nullptr ? std::string() : std::string(pattern));
    }

    regex(const std::string& pattern)
    {
        AssignPattern(pattern);
    }

    regex(const regex&) = default;
    regex(regex&&) noexcept = default;
    regex& operator=(const regex&) = default;
    regex& operator=(regex&&) noexcept = default;

    regex& assign(const char* pattern)
    {
        AssignPattern(pattern == nullptr ? std::string() : std::string(pattern));
        return *this;
    }

    regex& assign(const std::string& pattern)
    {
        AssignPattern(pattern);
        return *this;
    }

    bool empty() const
    {
        return !initialized_;
    }

    const std::regex& native() const
    {
        return expression_;
    }

private:
    void AssignPattern(const std::string& pattern)
    {
        expression_ = std::regex(pattern);
        initialized_ = !pattern.empty();
    }

    std::regex expression_;
    bool initialized_ = false;
};

template <typename T>
decltype(auto) unwrap_regex_arg(T&& value)
{
    return std::forward<T>(value);
}

inline const std::regex& unwrap_regex_arg(regex& value)
{
    return value.native();
}

inline const std::regex& unwrap_regex_arg(const regex& value)
{
    return value.native();
}

inline const std::regex& unwrap_regex_arg(regex&& value)
{
    return value.native();
}

template <typename... Args>
inline bool regex_match(Args&&... args)
{
    return std::regex_match(unwrap_regex_arg(std::forward<Args>(args))...);
}

template <typename... Args>
inline bool regex_search(Args&&... args)
{
    return std::regex_search(unwrap_regex_arg(std::forward<Args>(args))...);
}

template <typename... Args>
inline auto regex_replace(Args&&... args)
{
    return std::regex_replace(unwrap_regex_arg(std::forward<Args>(args))...);
}
} // namespace boost

#endif
