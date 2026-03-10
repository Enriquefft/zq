#!/bin/bash
# Progress utilities for benchmark suite
# All output goes to stderr to avoid contaminating benchmark measurements

# ANSI codes for colors and cursor control
COLOR_RESET='\033[0m'
COLOR_GREEN='\033[32m'
COLOR_BLUE='\033[34m'
COLOR_YELLOW='\033[33m'
COLOR_CYAN='\033[36m'
ERASE_LINE='\033[K'

# Global progress state
MAIN_PROGRESS=0
MAIN_TOTAL=4
PHASE_START_TIME=0

# Initialize main progress bar
init_main_progress() {
    MAIN_PROGRESS=0
    echo -e "${COLOR_CYAN}+=========================================================+${COLOR_RESET}" >&2
    echo -e "${COLOR_CYAN}|                   zq Benchmark Suite                    |${COLOR_RESET}" >&2
    echo -e "${COLOR_CYAN}+---------------------------------------------------------+${COLOR_RESET}" >&2
}

# Update main progress bar
update_main_progress() {
    local current=$1
    local total=$2
    local phase_name=$3

    MAIN_PROGRESS=$current

    # Clear line and show progress
    echo -ne "${ERASE_LINE}" >&2
    local percentage=$((current * 100 / total))
    local filled=$((percentage / 5))
    local empty=$((20 - filled))

    # Build progress bar string
    local bar=""
    local i=0
    while [ $i -lt $filled ]; do
        bar="${bar}="
        i=$((i + 1))
    done

    i=0
    while [ $i -lt $empty ]; do
        bar="${bar} "
        i=$((i + 1))
    done

    printf "\r${COLOR_GREEN}|${COLOR_RESET} [%s] %3d%% - %s${COLOR_GREEN}|${COLOR_RESET}" \
           "$bar" "$percentage" "$phase_name" >&2

    if [ $current -eq $total ]; then
        echo "" >&2
        echo -e "${COLOR_CYAN}+=========================================================+${COLOR_RESET}" >&2
    fi
}

# Start a phase timer
start_phase_timer() {
    PHASE_START_TIME=$(date +%s)
    echo -e "${COLOR_BLUE}>${COLOR_RESET} Starting: $1" >&2
}

# End a phase and show elapsed time
end_phase_timer() {
    local phase_name=$1
    local end_time=$(date +%s)
    local elapsed=$((end_time - PHASE_START_TIME))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))

    if [ $minutes -gt 0 ]; then
        echo -e "${COLOR_GREEN}✓${COLOR_RESET} Completed: $phase_name (${COLOR_YELLOW}${minutes}m ${seconds}s${COLOR_RESET})" >&2
    else
        echo -e "${COLOR_GREEN}✓${COLOR_RESET} Completed: $phase_name (${COLOR_YELLOW}${seconds}s${COLOR_RESET})" >&2
    fi
}

# Show a small progress indicator for long operations
show_operation_progress() {
    local operation=$1
    local total=$2
    local current=$3

    if [ $total -gt 1 ]; then
        local percentage=$((current * 100 / total))
        echo -ne "${ERASE_LINE}\r${COLOR_CYAN}  ${operation}${COLOR_RESET} [$current/$total] (${percentage}%)" >&2
    else
        echo -ne "${ERASE_LINE}\r${COLOR_CYAN}  ${operation}...${COLOR_RESET}" >&2
    fi
}

# Complete an operation progress
finish_operation_progress() {
    echo -ne "${ERASE_LINE}" >&2
}

# Show a spinner for indeterminate operations
show_spinner() {
    local operation=$1
    local pid=$2
    local delay=0.1
    local spinstr="/-\|"

    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf " ${COLOR_CYAN}${operation}${COLOR_RESET} [%c]${ERASE_LINE}\r" "$spinstr" >&2
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done

    printf "${ERASE_LINE}" >&2
}
