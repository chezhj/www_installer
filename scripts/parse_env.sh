#!/bin/bash

# Path to the configuration file
file_path="$1"

# Read the file and extract the SetEnv directive
while IFS= read -r line; do
    if [[ "$line" =~ ^SetEnv[[:space:]]+([[:alnum:]_]+)[[:space:]]+([^\ ]+)$ ]]; then
        var_name="${BASH_REMATCH[1]}"
        var_value="${BASH_REMATCH[2]}"
        export_statement="export ${var_name}=\"${var_value}\""
        echo "Executing: ${export_statement}"
        eval "${export_statement}"
    fi
done < "$file_path"
