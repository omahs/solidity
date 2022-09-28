#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# vim:ts=4:et
# This file is part of solidity.
#
# solidity is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# solidity is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with solidity.  If not, see <http://www.gnu.org/licenses/>
#
# (c) solidity contributors.
# ------------------------------------------------------------------------------
# Bash script to test the import/exports.
# ast import/export tests:
#   - first exporting a .sol file to JSON, then loading it into the compiler
#     and exporting it again. The second JSON should be identical to the first.

set -euo pipefail

READLINK=readlink
if [[ "$OSTYPE" == "darwin"* ]]; then
    READLINK=greadlink
fi
REPO_ROOT=$(${READLINK} -f "$(dirname "$0")"/..)
SOLIDITY_BUILD_DIR=${SOLIDITY_BUILD_DIR:-${REPO_ROOT}/build}
SOLC="${SOLIDITY_BUILD_DIR}/solc/solc"
SPLITSOURCES="${REPO_ROOT}/scripts/splitSources.py"

# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"

function print_usage
{
    fail "Usage: ${0} ast [--exit-on-error]."
}

function print_used_commands
{
    local test_directory="$1"
    local export_command="$2"
    local import_command="$3"
    printError "You can find the files used for this test here: ${test_directory}"
    printError "Used commands for test:"
    printError "# export"
    echo "$ ${export_command}" >&2
    printError "# import"
    echo "$ ${import_command}" >&2
}

function print_stderr_stdout
{
    local error_message="$1"
    local stderr_file="$2"
    local stdout_file="$3"
    printError "${error_message}"
    printError ""
    printError "stderr:"
    cat "${stderr_file}" >&2
    printError ""
    printError "stdout:"
    cat "${stdout_file}" >&2
}

IMPORT_TEST_TYPE=
EXIT_ON_ERROR=0
for PARAM in "$@"
do
    case "$PARAM" in
        ast) IMPORT_TEST_TYPE="ast" ;;
        --exit-on-error) EXIT_ON_ERROR=1 ;;
        *) print_usage ;;
    esac
done

SYNTAXTESTS_DIR="${REPO_ROOT}/test/libsolidity/syntaxTests"
ASTJSONTESTS_DIR="${REPO_ROOT}/test/libsolidity/ASTJSON"

FAILED=0
UNCOMPILABLE=0
TESTED=0

function ast_import_export_equivalence
{
    local sol_file="$1"
    local input_files=( "${@:2}" )

    # export ast - save ast json as expected result (silently)
    local export_command="$SOLC --combined-json ast --pretty-json --json-indent 4 ${input_files[*]} > expected.json 2> stderr_export.txt"
    if ! $SOLC --combined-json ast --pretty-json --json-indent 4 "${input_files[@]}" > expected.json 2> stderr_export.txt
    then
        print_stderr_stdout "ERROR: AST export failed for input file $sol_file." ./stderr_export.txt ./expected.json
        print_used_commands "$(pwd)" "${export_command}" "${import_command}"
        return 1
    fi

    # (re)import ast - and export it again as obtained result (silently)
    local import_command="$SOLC --import-ast --combined-json ast --pretty-json --json-indent 4 expected.json > obtained.json 2> stderr_import.txt"
    if ! $SOLC --import-ast --combined-json ast --pretty-json --json-indent 4 expected.json > obtained.json 2> stderr_import.txt
    then
        print_stderr_stdout "ERROR: AST export failed for input file $sol_file." ./stderr_import.txt ./obtained.json
        print_used_commands "$(pwd)" "${export_command}" "${import_command}"
        return 1
    fi

    # compare expected and obtained ast's
    if diff_files expected.json obtained.json
    then
        echo -n "✅"
    else
        printError "❌ ERROR: AST reimport failed for ${sol_file}"
        if [[ $EXIT_ON_ERROR == 1 ]]
        then
            print_used_commands "$(pwd)" "${export_command}" "${import_command}"
            return 1
        fi
        FAILED=$((FAILED + 1))
    fi
    TESTED=$((TESTED + 1))
}

# function tests whether exporting and importing again is equivalent.
# Results are recorded by adding to FAILED or UNCOMPILABLE.
# Also, in case of a mismatch a diff is printed
# Expected parameters:
# $1 name of the file to be exported and imported
# $2 any files needed to do so that might be in parent directories
function testImportExportEquivalence {
    local sol_file="$1"
    local input_files=( "${@:2}" )

    # if compilable
    if "$SOLC" --bin "${input_files[@]}" > /dev/null 2>&1
    then
        case "$IMPORT_TEST_TYPE" in
            ast) ast_import_export_equivalence "${sol_file}" "${input_files[@]}" ;;
            *) fail "Unknown import test type '${IMPORT_TEST_TYPE}'. Aborting." ;;
        esac
    else
        UNCOMPILABLE=$((UNCOMPILABLE + 1))
    fi
}

WORKINGDIR=$PWD

command_available "$SOLC" --version
command_available jq --version

case "$IMPORT_TEST_TYPE" in
    ast) TEST_DIRS=("${SYNTAXTESTS_DIR}" "${ASTJSONTESTS_DIR}") ;;
    *)  print_usage ;;
esac

# boost_filesystem_bug specifically tests a local fix for a boost::filesystem
# bug. Since the test involves a malformed path, there is no point in running
# tests on it. See https://github.com/boostorg/filesystem/issues/176
IMPORT_TEST_FILES=$(find "${TEST_DIRS[@]}" -name "*.sol" -and -not -name "boost_filesystem_bug.sol")

NSOURCES="$(echo "${IMPORT_TEST_FILES}" | wc -l)"
echo "Looking at ${NSOURCES} .sol files..."

for solfile in $IMPORT_TEST_FILES
do
    echo -n "·"
    # create a temporary sub-directory
    FILETMP=$(mktemp -d)
    cd "$FILETMP"

    set +e
    OUTPUT=$("$SPLITSOURCES" "$solfile")
    SPLITSOURCES_RC=$?
    set -e

    if [[ $SPLITSOURCES_RC == 0 ]]
    then
        IFS=' ' read -ra OUTPUT_ARRAY <<< "$OUTPUT"
        testImportExportEquivalence "$solfile" "${OUTPUT_ARRAY[@]}"
    elif [ $SPLITSOURCES_RC == 1 ]
    then
        testImportExportEquivalence "$solfile" "$solfile"
    elif [ $SPLITSOURCES_RC == 2 ]
    then
        # The script will exit with return code 2, if an UnicodeDecodeError occurred.
        # This is the case if e.g. some tests are using invalid utf-8 sequences. We will ignore
        # these errors, but print the actual output of the script.
        printError "\n\n${OUTPUT}\n\n"
        testImportExportEquivalence "$solfile" "$solfile"
    else
        # All other return codes will be treated as critical errors. The script will exit.
        printError "\n\nGot unexpected return code ${SPLITSOURCES_RC} from ${SPLITSOURCES}. Aborting."
        printError "\n\n${OUTPUT}\n\n"

        exit 1
    fi

    cd "${WORKINGDIR}"
    # Delete temporary files
    rm -rf "${FILETMP}"
done

echo

if (( FAILED == 0 ))
then
    echo "SUCCESS: ${TESTED} tests passed, ${FAILED} failed, ${UNCOMPILABLE} could not be compiled (${NSOURCES} sources total)."
else
    fail "FAILURE: Out of ${NSOURCES} sources, ${FAILED} failed, (${UNCOMPILABLE} could not be compiled)."
fi
