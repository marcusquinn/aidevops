#!/usr/bin/env bash
# Shell environment functions for setup.sh

# Detect the current running shell (not $SHELL which is the login default)
# Returns: "bash" or "zsh" or the shell name
detect_running_shell() {
	# TODO: Extract from setup.sh lines 1537-1546
	:
}

# Detect the user's preferred/default shell (what they'll use day-to-day)
detect_default_shell() {
	# TODO: Extract from setup.sh lines 1550-1553
	:
}

# Get the appropriate shell rc file for a given shell
# Usage: get_shell_rc "zsh" or get_shell_rc "bash"
get_shell_rc() {
	# TODO: Extract from setup.sh lines 1557-1590
	:
}

# Get all shell rc files that exist on the system
get_all_shell_rcs() {
	# TODO: Extract from setup.sh lines 1595-1620
	:
}

# Setup oh-my-zsh if not already installed
setup_oh_my_zsh() {
	# TODO: Extract from setup.sh lines 1626-1690
	:
}

# Setup shell compatibility (bash 3.2 on macOS, etc.)
setup_shell_compatibility() {
	# TODO: Extract from setup.sh lines 1698-1915
	:
}

# Add ~/.local/bin to PATH if not already present
add_local_bin_to_path() {
	# TODO: Extract from setup.sh lines 2754-2800
	:
}

# Setup shell aliases for aidevops
setup_aliases() {
	# TODO: Extract from setup.sh lines 2847-2948
	:
}
