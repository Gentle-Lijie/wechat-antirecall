#pragma once

// Called from the Message finalizer hook after the original finalizer has run. Cheap
// when the feature is off: it returns before touching the message.
void wechat_antirecall_keyword_alert_observe(void *message, int mode);
