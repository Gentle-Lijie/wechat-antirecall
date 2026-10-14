#pragma once

// Starts the (idempotent) background enforcement. Called once WeChat's core library is
// seen loading, independent of whether the revoke hook supports the build.
void wechat_antirecall_window_privacy_start(void);
