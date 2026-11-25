#!/bin/bash
#  TEST MINER CLIENT (Field Test Mode)
#  Same as miner.sh, but defaults to a test address. Use with test-server.js.
#  TARGET_ADDRESS in .env still takes priority if it is set.

export DEFAULT_TARGET="1AFtgmBG6TB8m5FqFYMVmff4aGaaxeH5q1"
exec bash "$(dirname "$0")/miner.sh"
