#!/bin/bash

#
# Screen scrapes Danmarks Kirker and adds geo coordinates, producing an XML
# file for each processed church. These files are intended for ingest into
# loar.kb.dk by an administrator.
#

###############################################################################
# CONFIG
###############################################################################

if [[ -s "kirke.conf" ]]; then
    source "kirke.conf"
fi
pushd ${BASH_SOURCE%/*} > /dev/null
if [[ -s "kirke.conf" ]]; then
    source "kirke.conf"
fi
: ${CHURCH_LIST_URL:="http://danmarkskirker.natmus.dk/laes-online/alle-beskrevne-kirker/"}
: ${PROJECT:="kirker"}
: ${OPENSTREETMAP_PROVIDER:="https://nominatim.openstreetmap.org"}
: ${MAX_RETRIES:="5"}
: ${DELAY_BETWEEN_RETRIES:="20"}
: ${DELAY_BETWEEN_REQUESTS:="2"}

: ${FORCE_METADATA:="false"} # If true, single church metadata processing is always done
: ${SKIP_OSM="false"} # If true, the OpenStreetMap-service is not called 

usage() {
    echo ""
    echo "Usage: ./kirker_harvest.sh"
    exit $1
}

check_parameters() {
    mkdir -p "$PROJECT"
    mkdir -p "$PROJECT/geo"
}

################################################################################
# FUNCTIONS
################################################################################

# URL name
get_church_urls() {
    if [[ ! -s "$PROJECT/kirker_urls.dat" ]]; then
        curl "$CHURCH_LIST_URL" | grep -o '<a[^>]\+churchlink[^>]\+>' | sed 's/.*\(http[^"]\+\).*title="\([^"]\+\)".*/\1 \2/' > "$PROJECT/kirker_urls.dat"
    else
        echo " - Skipping download of list of churches as $PROJECT/kirker_urls.dat already exists"
    fi
}

# Extract the content of all HTML paragraphs (<p>) that has the given class
qualified_paragraph() {
    local FILE="$1"
    local CLASS="$2"
    grep -o "<p class=\"${CLASS}\">[^<]*</p>" < "$FILE" | sed -e 's/.*<p[^<]*>\([^<]*\)<.*/\1/'
}

# Extract the content of all HTML divs (<div>) that has the given class
qualified_div() {
    local FILE="$1"
    local CLASS="$2"
    grep -o "<div class=\"${CLASS}\">[^<]*</div>" < "$FILE" | sed -e 's/.*<div[^<]*>\([^<]*\)<.*/\1/'
}

# Extend the given JSON with n values with the given key
add_json() {
    local JSON="$1"
    local KEY="$2"
    local VALUES="$3"
    while read -r VALUE; do
        if [[ "." != ".$VALUE" ]]; then
            JSON="${JSON}, $KEY:\"$VALUE\""
        fi
    done <<< $(sed 's/"/\\"/g' <<< "$VALUES")
    echo "$JSON"
}

# Extend the given XML with n values with the given key
add_xml() {
    local XML="$1"
    local KEY="$2"
    local VALUES="$3"
    while read -r VALUE; do
        if [[ "." != ".$VALUE" ]]; then
            XML="${XML}    <field name=\"$KEY\">$VALUE</field>"$'\n'
        fi
    done <<< $(sed 's/"/\\"/g' <<< "$VALUES")
    echo "$XML"
}

# Uses an OpenStreetMap-service to resolve geo coordinate for a church
resolve_coordinates() {
    local QUERY="$1"
    local QUERY=$(sed -e 's/Skt./Sankt/' -e 's/†//' -e 's/ /+/g' <<< "$QUERY")
    local DEST="$2"
    if [[ "$SKIP_OSM" == "false" && ( ! -s "$DEST" || ".[]" == .$(cat "$DEST") || "." != .$(grep 'You have been temporarily blocked' < "$DEST") ) ]]; then
        sleep $DELAY_BETWEEN_REQUESTS
        local ATTEMPT=1
        while [[ "$ATTEMPT" -le "$MAX_RETRIES" ]]; do
            curl -s "${OPENSTREETMAP_PROVIDER}/search?format=json&q=${QUERY}" > "$DEST"
            if [[ "." == .$(grep 'You have been temporarily blocked' < "$DEST") ]]; then
                break
            fi
            if [[ "$ATTEMPT" -ne "$MAX_RETRIES" ]]; then
                >&2 echo "Temporarily blocked while geo-searching '$QUERY'. Sleeping ${DELAY_BETWEEN_RETRIES} seconda and retrying"
                sleep $DELAY_BETWEEN_RETRIES
            fi
            ATTEMPT=$(( ATTEMPT+1 ))
        done
        if [[ ! -s "$DEST" || ".[]" == .$(cat "$DEST") ]]; then
            >&2 echo "Unable to resolve coordinates with '${OPENSTREETMAP_PROVIDER}/search?format=json&q=${QUERY}'"
            rm -f "$DEST"
            echo -n ""
            return
        fi
    fi
    if [[ -s "$DEST" ]]; then
        jq -r '.[0].lon, .[0].lat' < "$DEST" | tr '\n' ',' | sed 's/,$//'
    else
        echo ""
    fi
}  

# Takes a church name and resolves authors for the description of the church, if possible
# The author-list is 'kirker_authors.txt' and is manually maintained
resolve_authors() {
    local CHURCH="$1"
    if [[ $(grep "^${CHURCH}:" < kirker_authors.txt | wc -l) -ge 2 ]]; then
        >&2 echo "Error: The church '$CHURCH' has multiple entries in kirker_authors.txt. Please fix!"
        exit 4
    fi
    grep "^${CHURCH}:" < kirker_authors.txt | cut -d: -f2 | sed 's/, */\n/g'
}

# Fetch the HTML page for a single church and extract relevant metadata
get_single_church_metadata() {
    local CHURCH_URL="$1"
    local CHURCH_BASE=$(sed -e 's%/$%%' -e 's%.*/\([^/]*\)/\([^/]*\)$%\1_\2%' <<< "$CHURCH_URL")
    local CHURCH_RAW="$PROJECT/raw/${CHURCH_BASE}.html"
    local CHURCH_JSON="$PROJECT/json/${CHURCH_BASE}.json"
    local CHURCH_XML="$PROJECT/xml/${CHURCH_BASE}.xml"
    local CHURCH_OSM="$PROJECT/osm/${CHURCH_BASE}.json"

    if [[ -s "$CHURCH_XML" && "$FORCE_METADA" == "false" ]]; then
        echo "Exists: $CHURCH_XML"

        if [[ "." != .$(grep "place_coordinates" "$CHURCH_XML") ]]; then
            echo " - Skipping processing of $CHURCH:XML as coordinates are present"
            return
        fi
    fi
    echo " - Processing $CHURCH_XML"
    
    mkdir -p "$PROJECT/raw"
    mkdir -p "$PROJECT/osm"
   
    # Download HTML
    if [[ ! -s "$CHURCH_RAW" ]]; then
        echo "- Downloading $CHURCH_URL to $CHURCH_RAW"
        curl -s "$CHURCH_URL" > "$CHURCH_RAW"
    fi

    # Extract meta-data
    local PDF=$(grep -o '<a[^>]\+filelink[^>]\+>' < "$CHURCH_RAW" | grep -o 'http[^"]\+')
    local TITLE=$(grep -o '<title>.*</title>' < "$CHURCH_RAW" | sed -e 's/<title>\(.*\)<\/title>/\1/' -e 's/\(.*\) -.*/\1/')
    local AUTHORS=$(resolve_authors "$TITLE")
    
    local HERRED=$(qualified_paragraph "$CHURCH_RAW" "township")
    local AMT=$(qualified_paragraph "$CHURCH_RAW" "county")
    local ADDRESS=$(qualified_paragraph "$CHURCH_RAW" "address")
    local ZIP_CITY=$(qualified_paragraph "$CHURCH_RAW" "zipcity")
    local VOLUMES=$(qualified_div "$CHURCH_RAW" "volume")
    # TODO: What about spans? "XIX, bind 3 (1988-91)"
    local VOLUME_YEARS=$(grep -o '[12][0-9][0-9][0-9]' <<< "$VOLUMES" | sort | uniq)
    local ZIP_ONLY=$(grep -o "[0-9][0-9][0-9][0-9]" <<< "$ZIP_CITY")

    local COORDINATES=$(resolve_coordinates "${TITLE}, ${ZIP_ONLY}" "$CHURCH_OSM")

    if [[ "." == ".$COORDINATES" && "." != ".$ADDRESS" ]]; then
        echo "Falling back to resolving geo-coordinates from '${ADDRESS}, ${ZIP_ONLY}'"
        local COORDINATES=$(resolve_coordinates "${ADDRESS}, ${ZIP_ONLY}" "$CHURCH_OSM")
    fi
    
    if [[ "1" == "2" ]]; then
        # WARNING: Not synced with XML generation as it has been disabled
        
        #{id:"kirke_soenderjyllands-amt_arrild-kirke", title:"Arrild Kirke", external_resource:"http://danmarkskirker.natmus.dk/uploads/tx_tcchurchsearch/Sjyll_0031-0046.pdf", external_resource:"http://danmarkskirker.natmus.dk/uploads/tx_tcchurchsearch/Sjyll_2613-2652.pdf", external_resource:"http://danmarkskirker.natmus.dk/uploads/tx_tcchurchsearch/Sjyll_1264-1280_01.pdf", place_name:"Hviding Herred", place_name:"Tønder Amt", place_name:"Arnumvej 24, Arrild"}
        mkdir -p "$PROJECT/json"
        local JSON="{id:\"kirke_${CHURCH_BASE}\""
        JSON=$(add_json "$JSON" "title" "$TITLE")
        JSON=$(add_json "$JSON" "external_resource" "$PDF")
        JSON=$(add_json "$JSON" "place_name" "$HERRED")
        JSON=$(add_json "$JSON" "place_name" "$AMT")
        JSON=$(add_json "$JSON" "place_name" "$ADDRESS")
        JSON="${JSON}}"
        echo "$JSON" | tee "$CHURCH_JSON"
    else
        mkdir -p "$PROJECT/xml"
        local XML="<add>"$'\n'"  <doc>"$'\n'
        XML="${XML}    <field name=\"id\">kirke_${CHURCH_BASE}</field>"$'\n'
        XML=$(add_xml "$XML" "title" "$TITLE")$'\n'
        XML=$(add_xml "$XML" "author" "$AUTHORS")$'\n'
        XML=$(add_xml "$XML" "external_resource" "$PDF")$'\n'
        XML=$(add_xml "$XML" "origin" "$CHURCH_URL")$'\n'
        XML=$(add_xml "$XML" "place_name" "$HERRED")$'\n'
        XML=$(add_xml "$XML" "volume_ss" "$VOLUMES")$'\n'
        XML=$(add_xml "$XML" "date_issued_is" "$VOLUME_YEARS")$'\n'
        XML=$(add_xml "$XML" "place_name" "$AMT")$'\n'
        XML=$(add_xml "$XML" "place_name" "$ADDRESS")$'\n'
        XML=$(add_xml "$XML" "place_name" "$ZIP_CITY")$'\n'
        XML=$(add_xml "$XML" "place_coordinates" "$COORDINATES")$'\n'
        XML="${XML}  </doc>"$'\n'"</add>"$'\n'
        echo "   Created XML metadata $CHURCH_XML with coordinates $COORDINATES"
        echo "$XML" > "$CHURCH_XML"
    fi
}

get_all_church_metadata() {
    get_church_urls
    while read -r CHURCH_URL; do 
        get_single_church_metadata $(cut -d\  -f1 <<< "$CHURCH_URL")
    done < "$PROJECT/kirker_urls.dat"
}


###############################################################################
# CODE
###############################################################################

check_parameters "$@"
get_all_church_metadata
echo "Screen scraped and geo coordinate enhanced meta data available at $PROJECT/xml/"

#PROJECT="$PROJECT" SUB_SOURCE="xml" SUB_DEST="pdf_json" RESOURCE_FIELD="external_resource" RESOURCE_EXT=".pdf" URL_PREFIX="http://miaplacidus.statsbiblioteket.dk:9831/loarindexer/services/pdfinfo?isAllowed=y&sequence=1&url=" ALLOW_MULTI="true" ./fetch_resources.sh
#PROJECT="$PROJECT" SUB_SOURCE="xml" SUB_PDF_JSON="pdf_json" SUB_DEST="solr_ready" ./pdf_enrich.sh
