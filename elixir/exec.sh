#!/bin/sh
export HOME=/Users/<your-user>
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
exec /opt/homebrew/bin/claude "$@"