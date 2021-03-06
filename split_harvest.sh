#!/bin/bash

#
# Splits OAI-PMH harvested record collections into single records
#

###############################################################################
# CONFIG
###############################################################################

if [[ -s "meloar.conf" ]]; then
    source "meloar.conf"
fi
pushd ${BASH_SOURCE%/*} > /dev/null
if [[ -s "meloar.conf" ]]; then
    source "meloar.conf"
fi

: ${PROJECT:="$1"}

: ${OAI_PATTERN:="oai-pmh*.xml"}
# oai-pmh.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.xml

usage() {
    echo "Usage: ./split_harvest.sh <project>"
    echo ""
    echo "Where <project> is a folder with OAI-PMH-harvested records"
    exit $1
}

check_parameters() {
    if [[ "." == ".$PROJECT" ]]; then
        >&2 echo "Error: No project specified"
        usage 3
    fi
    if [[ ! -d "$PROJECT" ]]; then
        >&2 echo "Error: Folder $PROJECT does not exist"
        exit 2
    fi
}

################################################################################
# FUNCTIONS
################################################################################

split_records() {
    pushd "$PROJECT" > /dev/null
    mkdir -p records
    HCOUNT=0
    echo "Extracting single records in $PROJECT"
    for HARVEST in $OAI_PATTERN; do
        echo "- $HARVEST"
        HCOUNT=$(( HCOUNT+1 ))
        xmllint --format $HARVEST | csplit -s -n 3 -f "${HARVEST}.record_" - '/<record>/' '{*}'
        for FF in "${HARVEST}.record_"*; do
            grep -A 99999 "<record>" $FF | grep -B 99999 "</record>" > ${FF}.xml
            if [[ ! -s ${FF}.xml ]]; then # No empty records
                rm ${FF}.xml
            else
                mv ${FF}.xml records/$(sed 's/[.]xml[.]/./' <<< "$FF").xml
            fi
            rm $FF
        done
    done
    echo "Finished extracting $(find . -iname "*.xml" | wc -l) records to $(pwd)/records/"
    popd > /dev/null
}

###############################################################################
# CODE
###############################################################################

check_parameters "$@"
split_records
