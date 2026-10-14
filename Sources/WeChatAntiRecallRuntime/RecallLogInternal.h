#pragma once
#include <string>

namespace recall_log {

// Appends one line to the recall log when the user opted in. `xml` is the raw revoke
// sysmsg, `notice` the tip WeChat rendered for it, `content` the preview captured on
// the receive path (nullptr on a cold-cache miss). Best effort: never throws and never
// blocks the message thread on disk I/O.
void record(const std::string &xml, const std::string &notice, const std::string *content);

}  // namespace recall_log
