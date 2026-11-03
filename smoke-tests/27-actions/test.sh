#!/usr/bin/env bash

# The frontend runs one of the app's actions by its name and lists the actions: the "Run the say action" button runs say-action
# through window.ziggy.runAction, and its handler writes its line; the "List the actions" button shows listActions, which holds the
# app's action and the standard items of its menu, quit among them.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app
click run-say-action
wait_for_text action-result "said by an action" 30
click list-actions
wait_for_text action-result "say-action Say From an Action" 30
wait_for_text action-result "quit" 30
